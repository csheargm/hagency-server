//! Where an Agent's answer goes in a group room (ADR 0004).
//!
//! A room chooses with one state event, [`STATE_EVENT`] (`state_key` ""):
//! `{"mode":"room"}` (also what a room without the event gets) puts the answer
//! to a top-level request in the main timeline as a reply quoting it, so every
//! member sees the conversation; `{"mode":"thread"}` keeps the earlier thread
//! under the request. A request a person wrote inside a thread is answered in
//! that thread either way, and a top-level owner DM stays flat.
//!
//! The mode is read from the same room-state snapshot as the delivery facts
//! the send is authorized on (`DeliveryFacts::reply_mode`), never a second read.
//!
//! Hagency Desktop's `hagency_core::agent_replies` carries the same contract
//! for the replies its Agent device posts; the strings below are pinned by
//! tests on both sides.
use crate::transport::ReplyIntent;
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

/// True when the answer to `event` (stored under `root`) is a main-timeline
/// reply: a top-level request in a project room that did not choose threads.
/// Personal-scope rooms (`owner_direct`) keep their stored shape, including
/// legacy intents whose root is the request itself (`workers::reply_content`).
pub fn is_flat(mode: Mode, owner_direct: bool, event: &str, root: &str) -> bool {
    mode == Mode::Room && !owner_direct && root.starts_with('$') && root == event
}

/// The answer's content, placed by the room's choice: a top-level group
/// request gets a main-timeline reply quoting it unless the room keeps Agent
/// replies in threads.
/// `mode` comes from the delivery snapshot the send was authorized on.
pub fn answer_content(mode: Mode, owner_direct: bool, intent: &ReplyIntent) -> Value {
    if is_flat(mode, owner_direct, &intent.request_event_id, &intent.thread_root) {
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
        assert!(is_flat(Mode::Room, false, "$q", "$q"));
        assert!(!is_flat(Mode::Thread, false, "$q", "$q"), "the threads setting");
        assert!(!is_flat(Mode::Room, false, "$followup", "$root"), "a person's thread");
        assert!(!is_flat(Mode::Room, true, "$q", "!dm:x"), "an owner DM");
        assert!(!is_flat(Mode::Room, true, "$q", "$q"), "a legacy owner-DM intent rooted at its request");
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
    /// "threads" setting brings the thread back.
    #[test]
    fn an_answer_is_a_main_timeline_reply_unless_the_room_chose_threads() {
        let flat = answer_content(Mode::of(&state(None)), false, &intent("$q"));
        assert_eq!(flat["m.relates_to"], json!({"m.in_reply_to":{"event_id":"$q"}}));
        assert!(flat["body"].as_str().unwrap().starts_with("> <@anna:x> @anna-claude what are the issues?\n\n"));
        let threaded = answer_content(Mode::of(&state(Some("thread"))), false, &intent("$q"));
        assert_eq!(threaded["m.relates_to"]["rel_type"], "m.thread");
        assert_eq!(threaded["body"], "Three issues.");
        let inside = answer_content(Mode::Room, false, &intent("$root"));
        assert_eq!(inside["m.relates_to"]["event_id"], "$root", "a person's thread keeps its answer");
    }

    /// GPT review: personal-scope intents keep the shape they were stored with.
    #[test]
    fn owner_direct_intents_keep_their_stored_shape() {
        let mut legacy = intent("$q");
        legacy.room_id = "!dm:x".into();
        assert_eq!(answer_content(Mode::Room, true, &legacy), crate::workers::reply_content(true, "!dm:x", "$q", "Three issues."));
        let mut top = intent("!dm:x");
        top.room_id = "!dm:x".into();
        assert!(answer_content(Mode::Room, true, &top).get("m.relates_to").is_none());
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
