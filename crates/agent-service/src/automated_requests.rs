//! Requests that a Hagency automation posted, not a person typing. The desktop
//! issue watcher posts its hand-offs, review-loop prompts and tracker lines
//! from the owner's own account, so the sender cannot tell them apart; each
//! carries one of these content fields instead (desktop
//! `src/hagency/issue_watch/{notice,loop_notice,tracker_live}.rs`). Nobody
//! watches those rooms waiting for them, so they get no interim status at all:
//! no "Working…" line, only the final reply or failure (owner, 2026-11-18).
use serde_json::Value;

/// Content fields that mark a message as a Hagency automation's.
pub(crate) const AUTOMATION_MARKERS: [&str; 3] =
    ["io.hagency.issue_handoff", "io.hagency.review_loop", "io.hagency.issue_track"];

/// Whether this plaintext message content was posted by an automation.
pub(crate) fn is_automated(content: &Value) -> bool {
    AUTOMATION_MARKERS.iter().any(|marker| content.get(marker).is_some_and(Value::is_object))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn an_issue_hand_off_is_automated_and_a_typed_request_is_not() {
        let handoff = json!({"msgtype":"m.text","body":"@agent fix #12","io.hagency.issue_handoff":{"number":12}});
        assert!(is_automated(&handoff));
        assert!(is_automated(&json!({"body":"x","io.hagency.review_loop":{}})));
        assert!(is_automated(&json!({"body":"x","io.hagency.issue_track":{}})));
        let typed = json!({"msgtype":"m.text","body":"@agent fix #12","io.hagency.activity":{}});
        assert!(!is_automated(&typed), "a person's message with other Hagency fields still gets status");
        assert!(!is_automated(&json!({"body":"x","io.hagency.issue_handoff":null})), "the watcher's marker is an object");
    }

    #[test]
    fn a_routed_hand_off_carries_the_mark_and_keeps_old_digests() {
        let raw = |content: Value| json!({"type":"m.room.message","event_id":"$h","room_id":"!r:x","sender":"@owner:x","content":content});
        let handoff = crate::workers::parse_event(&raw(json!({"msgtype":"m.text","body":"fix #3","io.hagency.issue_handoff":{}}))).unwrap();
        assert!(handoff.automated);
        let typed = crate::workers::parse_event(&raw(json!({"msgtype":"m.text","body":"fix #3"}))).unwrap();
        assert!(!typed.automated);
        assert!(serde_json::to_value(&typed).unwrap().get("automated").is_none());
    }
}
