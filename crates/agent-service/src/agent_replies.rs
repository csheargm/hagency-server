//! Where an Agent's answer goes in a group room (ADR 0004).
//!
//! A room chooses with one state event, [`STATE_EVENT`] (`state_key` ""):
//! `{"mode":"room"}` (also what a room without the event gets) puts the answer
//! to a top-level request in the main timeline as a reply quoting it, so every
//! member sees the conversation; `{"mode":"thread"}` keeps the earlier thread
//! under the request. A request a person wrote inside a thread is answered in
//! that thread either way, and a top-level owner DM stays flat.
//!
//! Hagency Desktop's `hagency_core::agent_replies` carries the same contract
//! for the replies its Agent device posts; the strings below are pinned by
//! tests on both sides.
use crate::{gateway::Gateway, transport::ReplyIntent};
use serde_json::{Value, json};

/// The room state event that holds the choice.
pub const STATE_EVENT: &str = "im.hagency.agent_replies";
/// Longest quoted request in a reply's plain-text fallback, in characters.
pub const QUOTE_CHARS: usize = 80;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Mode {
    /// In the main timeline, as a reply quoting the request.
    #[default]
    Room,
    /// In a thread under the request.
    Thread,
}

impl Mode {
    /// The mode a room's state names; anything else is the default.
    pub fn of(state: &[Value]) -> Self {
        let content = state
            .iter()
            .find(|e| e["type"] == STATE_EVENT && e["state_key"] == "")
            .map(|e| &e["content"]);
        match content.and_then(|c| c["mode"].as_str()) {
            Some("thread") => Self::Thread,
            _ => Self::Room,
        }
    }
}

/// The room's choice, read fresh with the delivery facts' own state source.
pub async fn room_mode(gateway: &Gateway, room: &str) -> Mode {
    match gateway.state(room).await {
        Ok(state) => Mode::of(&state),
        Err(error) => {
            // The delivery check read this state moments ago; a failed second
            // read must not hold the answer back. The default (main timeline)
            // is what a room that never chose gets, and the reason is logged.
            tracing::warn!(code = %error, "Agent reply mode unavailable; replying in the room");
            Mode::default()
        }
    }
}

/// True when the answer to `event` (stored under `root`) is a main-timeline
/// reply: a top-level group request in a room that did not choose threads.
pub fn is_flat(mode: Mode, owner_direct: bool, room: &str, event: &str, root: &str) -> bool {
    mode == Mode::Room && !(owner_direct && root == room) && root.starts_with('$') && root == event
}

/// The answer's content, placed by the room's choice: a top-level group
/// request gets a main-timeline reply quoting it unless the room keeps Agent
/// replies in threads.
pub async fn answer_content(gateway: &Gateway, owner_direct: bool, intent: &ReplyIntent) -> Value {
    let mode = room_mode(gateway, &intent.room_id).await;
    if is_flat(mode, owner_direct, &intent.room_id, &intent.request_event_id, &intent.thread_root) {
        return flat_reply_content(&intent.request_event_id, &intent.requester_mxid, &intent.request_body, &intent.body);
    }
    crate::workers::reply_content(owner_direct, &intent.room_id, &intent.thread_root, &intent.body)
}

/// A main-timeline answer to `event`, quoting `request` (by `requester`) in
/// the plain body for clients that do not render replies.
pub fn flat_reply_content(event: &str, requester: &str, request: &str, body: &str) -> Value {
    let mut content = json!({"msgtype":"m.text","body":body,"m.relates_to":{"m.in_reply_to":{"event_id":event}}});
    crate::reply_format::add_markdown(&mut content);
    // After the HTML is rendered: the quote lives in the plain body only, so
    // a client that renders the reply relation shows it once.
    content["body"] = json!(with_quote_fallback(requester, request, body));
    content
}

/// `body` behind `> <@requester> first line of the request` and a blank line;
/// a request with no text leaves `body` as it is.
pub fn with_quote_fallback(requester: &str, request: &str, body: &str) -> String {
    let Some(line) = request.lines().map(str::trim).find(|l| !l.is_empty()) else {
        return body.to_owned();
    };
    let mut quoted: String = line.chars().take(QUOTE_CHARS).collect();
    if line.chars().count() > QUOTE_CHARS {
        quoted.push('…');
    }
    format!("> <{requester}> {quoted}\n\n{body}")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn state(mode: Option<&str>) -> Vec<Value> {
        let mut state = vec![json!({"type":"m.room.create","state_key":"","content":{}})];
        if let Some(mode) = mode {
            state.push(json!({"type":STATE_EVENT,"state_key":"","content":{"mode":mode}}));
        }
        state
    }

    #[test]
    fn rooms_answer_in_the_timeline_unless_they_chose_threads() {
        assert_eq!(STATE_EVENT, "im.hagency.agent_replies", "Hagency Desktop pins the same string");
        assert_eq!(Mode::of(&state(None)), Mode::Room);
        assert_eq!(Mode::of(&state(Some("room"))), Mode::Room);
        assert_eq!(Mode::of(&state(Some("unknown"))), Mode::Room);
        assert_eq!(Mode::of(&state(Some("thread"))), Mode::Thread);
    }

    #[test]
    fn only_a_top_level_group_request_in_room_mode_is_flat() {
        assert!(is_flat(Mode::Room, false, "!r:x", "$q", "$q"));
        assert!(!is_flat(Mode::Thread, false, "!r:x", "$q", "$q"), "the threads setting");
        assert!(!is_flat(Mode::Room, false, "!r:x", "$followup", "$root"), "a person's thread");
        assert!(!is_flat(Mode::Room, true, "!dm:x", "$q", "!dm:x"), "an owner DM");
    }

    fn gateway(state: Option<Vec<Value>>) -> Gateway {
        let read: crate::gateway::ReadState = std::sync::Arc::new(move |_room| {
            let state = state.clone();
            Box::pin(async move { state.ok_or(crate::Error::Unavailable("matrix_state_unavailable")) })
        });
        Gateway::new(read, "@_hagency_service:x".into())
    }
    fn intent(root: &str) -> ReplyIntent {
        ReplyIntent {
            id: "rpl_1".into(), owner_event_id: "evt_1".into(), requester_mxid: "@anna:x".into(),
            agent_id: "agt_1".into(), binding_id: "bnd_1".into(), owner_user_id: "usr_1".into(),
            room_id: "!dev:x".into(), puppet_mxid: "@anna-claude:x".into(), thread_root: root.into(),
            body: "Three issues.".into(), payload_digest: String::new(), matrix_txn_id: "hg-1".into(),
            binding_generation: 1, dispatch_epoch: 1, delivery_epoch: 1, state: "sending".into(),
            delivery_blocked: false, worker_token: None, worker_until_ms: 0, matrix_event_id: None,
            request_event_id: "$q".into(), request_body: "@anna-claude what are the issues?".into(),
        }
    }

    /// The user flow: Anna asks in the dev room; Betty, another member, reads
    /// the answer in the main timeline under the quoted question. The room's
    /// "threads" setting brings the thread back; a failed state read still answers.
    #[tokio::test]
    async fn an_answer_is_a_main_timeline_reply_unless_the_room_chose_threads() {
        let flat = answer_content(&gateway(Some(state(None))), false, &intent("$q")).await;
        assert_eq!(flat["m.relates_to"], json!({"m.in_reply_to":{"event_id":"$q"}}));
        assert!(flat["body"].as_str().unwrap().starts_with("> <@anna:x> @anna-claude what are the issues?\n\n"));
        let threaded = answer_content(&gateway(Some(state(Some("thread")))), false, &intent("$q")).await;
        assert_eq!(threaded["m.relates_to"]["rel_type"], "m.thread");
        assert_eq!(threaded["body"], "Three issues.");
        let inside = answer_content(&gateway(Some(state(None))), false, &intent("$root")).await;
        assert_eq!(inside["m.relates_to"]["event_id"], "$root", "a person's thread keeps its answer");
        let unreadable = answer_content(&gateway(None), false, &intent("$q")).await;
        assert!(unreadable["m.relates_to"]["rel_type"].is_null());
    }

    #[test]
    fn a_flat_reply_quotes_the_request_in_the_plain_body_only() {
        let c = flat_reply_content("$q", "@anna:x", "what are the issues?\nmore", "**Three.**");
        assert_eq!(c["m.relates_to"], json!({"m.in_reply_to":{"event_id":"$q"}}));
        assert_eq!(c["body"], "> <@anna:x> what are the issues?\n\n**Three.**");
        let html = c["formatted_body"].as_str().unwrap();
        assert!(html.contains("<strong>Three.</strong>") && !html.contains("issues"), "{html}");
        assert_eq!(with_quote_fallback("@a:x", "", "ok"), "ok");
        let long = with_quote_fallback("@a:x", &"z".repeat(QUOTE_CHARS + 1), "ok");
        assert!(long.starts_with(&format!("> <@a:x> {}…", "z".repeat(QUOTE_CHARS))));
    }
}
