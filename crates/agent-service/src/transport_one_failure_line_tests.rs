//! One line per outcome (owner, 2026-11-18): a failure the executor's run
//! card shows gets no server notice, an automation's failure and reply stay
//! on its tracker's lines, and a person's plain failure keeps its notice.
use super::tests::{enqueue, event, fixture, running, running_with};
use super::*;

async fn kinds(t: &TransportStore, id: &str) -> Vec<String> {
    let due = t.request_notice_candidates("", crate::api::now_ms()).await.unwrap();
    due.into_iter().filter(|n| n.owner_event_id == id).map(|n| n.kind).collect()
}

#[tokio::test]
#[ignore = "requires dedicated PostgreSQL database via HAGENCY_AGENT_TEST_DATABASE_URL"]
async fn postgres_a_failure_on_the_run_card_is_the_only_failure_line() {
    let f = fixture().await;
    let t = &f.transport;
    let now = crate::api::now_ms();
    let lease = t.acquire_for_test(&f.p, &f.agent, 60_000, false, now).await.unwrap();
    let lease = LeaseRef { agent_id: f.agent.clone(), epoch: lease.epoch };
    let carded = enqueue(&f, "failed-on-card").await;
    // A card exists only for a started run: an offered dispatch is not retired this way.
    t.claim_event(&f.p, &lease, &carded, &f.facts, now).await.unwrap();
    assert!(matches!(t.finish_failed_on_card(&f.p, &lease, &carded, "card-run", now).await, Err(Error::Conflict("execution_not_running"))));
    t.acknowledge(&f.p, &lease, &carded, now).await.unwrap();
    t.start_execution(&f.p, &lease, &carded, "card-run", &f.facts, now).await.unwrap();
    // Another device cannot claim the card for this run.
    assert!(t.finish_failed_on_card(&f.second, &lease, &carded, "card-run", now).await.is_err());
    t.finish_failed_on_card(&f.p, &lease, &carded, "card-run", now).await.unwrap();
    t.finish_failed_on_card(&f.p, &lease, &carded, "card-run", now).await.unwrap(); // a retried report is the same record
    assert!(kinds(t, &carded).await.is_empty(), "the card already says it failed, with the policy guidance");
    let plain = enqueue(&f, "failed-no-card").await;
    running(&f, &lease, &plain, "plain-run").await;
    t.finish_without_reply(&f.p, &lease, &plain, "plain-run", "failed", now).await.unwrap();
    assert_eq!(kinds(t, &plain).await, vec!["failed"], "no card showed it: the server's notice is the one line");
}

#[tokio::test]
#[ignore = "requires dedicated PostgreSQL database via HAGENCY_AGENT_TEST_DATABASE_URL"]
async fn postgres_an_automations_reply_and_failure_stay_off_the_room() {
    let f = fixture().await;
    let t = &f.transport;
    let now = crate::api::now_ms();
    // The watcher posts from the Agent owner's own account.
    let owner = DeliveryFacts { requester_mxid: f.facts.owner_mxid.clone(), ..f.facts.clone() };
    let mut ids = vec![];
    for (name, automated, sender) in [("quiet-handoff", true, &owner), ("failed-handoff", true, &owner), ("typed-request", false, &owner), ("member-marker", true, &f.facts)] {
        let routed = RoutedEvent { automated, sender_mxid: sender.requester_mxid.clone(), ..event(&f, name, true, None) };
        let RouteResult::Queued { dispatch_id } = t.ingest_routed(&f.binding, routed, sender, now).await.unwrap() else { panic!("queued") };
        ids.push(dispatch_id);
    }
    let lease = t.acquire_for_test(&f.p, &f.agent, 60_000, false, now).await.unwrap();
    let lease = LeaseRef { agent_id: f.agent.clone(), epoch: lease.epoch };
    let answer = |id: &str, run: &str| SubmitReply { dispatch_id: id.into(), execution_id: run.into(), body: "Opened PR #9".into() };
    running_with(&f, &owner, &lease, &ids[0], "quiet-run").await;
    let quiet = t.submit_reply(&f.p, &lease, answer(&ids[0], "quiet-run"), &owner, now).await.unwrap();
    assert_eq!((quiet.state.as_str(), quiet.body.as_str()), ("sent", "Opened PR #9"), "kept and completed, never posted");
    assert_eq!(quiet.matrix_event_id.as_deref(), Some("$quiet-handoff"), "recorded against the request, so the device settles it");
    running_with(&f, &owner, &lease, &ids[1], "failed-run").await;
    t.finish_without_reply(&f.p, &lease, &ids[1], "failed-run", "failed", now).await.unwrap();
    assert!(kinds(t, &ids[1]).await.is_empty(), "the tracker's line reports a lost run");
    let mut posted = vec![];
    for (index, run) in [(2, "typed-run"), (3, "member-run")] {
        let facts = if index == 2 { &owner } else { &f.facts };
        running_with(&f, facts, &lease, &ids[index], run).await;
        let reply = t.submit_reply(&f.p, &lease, answer(&ids[index], run), facts, now).await.unwrap();
        assert_eq!(reply.state, "pending", "{run}: a person's reply is posted as before");
        posted.push(reply.id);
    }
    let due = t.reply_candidates(100, crate::api::now_ms()).await.unwrap();
    assert!(posted.iter().all(|id| due.iter().any(|r| &r.id == id)) && due.iter().all(|r| r.id != quiet.id));
}
