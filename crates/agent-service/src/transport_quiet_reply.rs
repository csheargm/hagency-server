//! A request a Hagency automation posted (the issue watcher's hand-off or a
//! review-loop step, `automated_requests`) is answered on its tracker's own
//! room lines: the issue loop reads the run's end from the executor's ledger
//! and GitHub, never from this reply. Its reply is still recorded (the
//! dispatch completes, its text is kept like any plaintext reply) but as
//! already sent, so nothing posts it to the room (owner, 2026-11-18). A run
//! card that carries the answer (`record_card_reply`) is unaffected.
//!
//! Only the Agent owner's own automation counts: the watcher posts from the
//! owner's account, and a room member who sets the marker on their own
//! message still gets a visible reply (GPT review). The reply is recorded
//! against the request's own event, the one Matrix event it answers, so the
//! executor's delivery check (a sent receipt names an event) settles it and
//! never resends it.
use super::*;

/// The SQL condition, over owner event `e` and its Agent owner `u`, for an
/// automation's request; `request_notice_needed.sql` repeats it verbatim.
pub(super) const OWNER_AUTOMATION: &str = "e.automated AND e.requester_mxid=u.mxid";

/// The reply's state and Matrix event for owner event `e`: a quiet reply is
/// already sent, recorded against the request event; any other is pending.
pub(super) async fn disposition(db: &mut AsyncPgConnection, e: &Dispatch) -> Result<(&'static str, Option<String>)> {
    let quiet = sql_query(format!("SELECT {OWNER_AUTOMATION} AS matched FROM hagency_agent_v1.owner_events e JOIN hagency_agent_v1.agents a ON a.id=e.agent_id JOIN hagency_agent_v1.users u ON u.id=a.owner_user_id WHERE e.id=$1"))
        .bind::<Text, _>(&e.id)
        .get_result::<Flag>(db)
        .await?
        .matched;
    Ok(if quiet { ("sent", Some(e.event_id.clone())) } else { ("pending", None) })
}

#[test]
fn the_notice_view_repeats_the_owner_automation_condition() {
    assert!(include_str!("request_notice_needed.sql").contains(OWNER_AUTOMATION));
}
