//! ADR 0003: an owner who left the Agent's private chat gets it back.
use super::*;
use crate::{api_owner_direct::{DirectMatrix, recover}, domain::Agent, gateway::Gateway};
use serde_json::{Value, json};
use std::{collections::HashMap, sync::{Arc, Mutex}};

type Rooms = Arc<Mutex<HashMap<String, Vec<Value>>>>;
/// Homeserver stand-in: room state the gateway reads and the puppet changes.
#[derive(Clone, Default)]
struct Fake {
    rooms: Rooms,
    invites: Arc<Mutex<Vec<(String, String, String)>>>,
    created: Arc<Mutex<Vec<String>>>,
    left: Arc<Mutex<Vec<String>>>,
    /// Rooms created encrypted.
    encrypted: Arc<Mutex<Vec<String>>>,
    /// The next invite fails: `true` as a Matrix refusal, `false` as unknown.
    invite_fails: Arc<Mutex<Option<bool>>>,
}
fn set_member(state: &mut Vec<Value>, user: &str, membership: &str) {
    state.retain(|e| !(e["type"] == "m.room.member" && e["state_key"] == user));
    state.push(json!({"type":"m.room.member","state_key":user,"content":{"membership":membership}}));
}
fn private_room(owner: &str, puppet: &str, owner_membership: &str, puppet_membership: &str) -> Vec<Value> {
    let mut state = vec![
        json!({"type":"m.room.create","state_key":"","content":{}}),
        json!({"type":"m.room.join_rules","state_key":"","content":{"join_rule":"invite"}}),
        json!({"type":"m.room.history_visibility","state_key":"","content":{"history_visibility":"joined"}}),
        json!({"type":"m.room.guest_access","state_key":"","content":{"guest_access":"forbidden"}}),
    ];
    set_member(&mut state, owner, owner_membership);
    set_member(&mut state, puppet, puppet_membership);
    state
}
impl Fake {
    fn gateway(&self) -> Gateway {
        let rooms = self.rooms.clone();
        Gateway::new(
            Arc::new(move |room| {
                let state = rooms.lock().unwrap().get(&room).cloned();
                Box::pin(async move { state.ok_or(Error::Unavailable("matrix_state_unavailable")) })
            }),
            "@_hagency_service:example.test".into(),
        )
    }
    fn member(&self, room: &str, user: &str, membership: &str) {
        set_member(self.rooms.lock().unwrap().get_mut(room).unwrap(), user, membership);
    }
}
impl DirectMatrix for Fake {
    async fn invite_owner(&self, puppet: &str, room: &str, owner: &str) -> Result<()> {
        match self.invite_fails.lock().unwrap().take() {
            Some(true) => return Err(Error::Conflict("matrix_permission_missing")),
            Some(false) => return Err(Error::Unavailable("matrix_outcome_unknown")),
            None => {}
        }
        self.invites.lock().unwrap().push((puppet.into(), room.into(), owner.into()));
        self.member(room, owner, "invite");
        Ok(())
    }
    async fn create_owner_direct(&self, agent: &Agent, owner: &str, encrypted: bool) -> Result<String> {
        // Yield while "creating", so a concurrent recovery could overlap here.
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        let room = format!("!replacement_{}:example.test", crate::secret_token());
        // Nobody is invited at creation; the owner is invited after the swap.
        self.rooms.lock().unwrap().insert(room.clone(), private_room(owner, &agent.puppet_mxid, "leave", "join"));
        self.created.lock().unwrap().push(room.clone());
        if encrypted {
            self.encrypted.lock().unwrap().push(room.clone());
        }
        Ok(room)
    }
    async fn leave(&self, puppet: &str, room: &str) -> Result<()> {
        self.left.lock().unwrap().push(room.into());
        self.member(room, puppet, "leave");
        Ok(())
    }
}

/// A fixture Agent whose owner-direct Room is adopted and active.
async fn direct() -> (Fixture, Fake, String) {
    let f = fixture().await;
    let fake = Fake::default();
    let room = format!("!direct_{}:example.test", crate::secret_token());
    let puppet = f.facts.puppet_mxid.clone();
    fake.rooms.lock().unwrap().insert(room.clone(), private_room(&f.p.mxid, &puppet, "join", "invite"));
    let now = crate::api::now_ms();
    let facts = fake.gateway().room(&room, "", &f.p.mxid, Some(&puppet)).await.unwrap();
    let adopted = f.domain.adopt_owner_direct(&f.p, &f.agent, &room, &facts, now).await.unwrap();
    fake.member(&room, &puppet, "join");
    let joined = fake.gateway().room(&room, "", &f.p.mxid, Some(&puppet)).await.unwrap();
    f.domain.verify_provisioning_trusted(&adopted.binding.id, adopted.binding.generation, &joined, true, now).await.unwrap();
    (f, fake, room)
}
async fn run(f: &Fixture, fake: &Fake) -> Result<Value> {
    recover(&f.domain, &fake.gateway(), fake, &f.p, &f.agent, crate::api::now_ms).await
}
async fn direct_bindings(f: &Fixture) -> Vec<crate::domain::Binding> {
    let all = f.domain.bindings(&f.p, &f.agent, crate::api::now_ms()).await.unwrap();
    all.into_iter().filter(|b| b.scope_kind == "owner_direct").collect()
}

#[tokio::test]
#[ignore = "requires dedicated PostgreSQL database via HAGENCY_AGENT_TEST_DATABASE_URL"]
async fn postgres_owner_already_joined_is_a_no_op() {
    let (f, fake, room) = direct().await;
    let reply = run(&f, &fake).await.unwrap();
    assert_eq!(reply, json!({"outcome":"joined","ownerDirectRoomId":room}));
    assert!(fake.invites.lock().unwrap().is_empty() && fake.created.lock().unwrap().is_empty());
}

#[tokio::test]
#[ignore = "requires dedicated PostgreSQL database via HAGENCY_AGENT_TEST_DATABASE_URL"]
async fn postgres_owner_who_left_is_reinvited_to_the_same_room() {
    let (f, fake, room) = direct().await;
    let puppet = f.facts.puppet_mxid.clone();
    fake.member(&room, &f.p.mxid, "leave");
    let reply = run(&f, &fake).await.unwrap();
    assert_eq!(reply, json!({"outcome":"reinvited","ownerDirectRoomId":room}));
    assert_eq!(*fake.invites.lock().unwrap(), vec![(puppet.clone(), room.clone(), f.p.mxid.clone())], "the puppet invites only its owner");
    assert!(fake.created.lock().unwrap().is_empty());
    // The reconciler sees the owner invited but not joined: the grace keeps the binding.
    let binding = direct_bindings(&f).await.remove(0);
    let invited = fake.gateway().room(&room, "", &f.p.mxid, Some(&puppet)).await.unwrap();
    assert!(!invited.owner_in_room);
    assert!(!f.domain.retire_membership_loss_trusted(&binding.id, binding.generation, &invited, crate::api::now_ms()).await.unwrap());
    // Idempotent: a second call sees the waiting invitation and invites nobody.
    assert_eq!(run(&f, &fake).await.unwrap()["outcome"], "invited");
    assert_eq!(fake.invites.lock().unwrap().len(), 1);
    assert_eq!(f.domain.agent(&f.p, &f.agent, crate::api::now_ms()).await.unwrap().owner_direct_room_id.as_deref(), Some(room.as_str()));
    // Without the grace, the owner's absence still retires the binding.
    let late = crate::api::now_ms() + crate::domain::OWNER_REJOIN_GRACE_MS + 1;
    let stale = RoomFacts { observed_at_ms: late, ..invited.clone() };
    assert!(f.domain.retire_membership_loss_trusted(&binding.id, binding.generation, &stale, late).await.unwrap());
}

#[tokio::test]
#[ignore = "requires dedicated PostgreSQL database via HAGENCY_AGENT_TEST_DATABASE_URL"]
async fn postgres_rejoin_grace_ends_once_the_owner_is_back() {
    let (f, fake, room) = direct().await;
    let puppet = f.facts.puppet_mxid.clone();
    fake.member(&room, &f.p.mxid, "leave");
    assert_eq!(run(&f, &fake).await.unwrap()["outcome"], "reinvited");
    let binding = direct_bindings(&f).await.remove(0);
    fake.member(&room, &f.p.mxid, "join");
    let joined = fake.gateway().room(&room, "", &f.p.mxid, Some(&puppet)).await.unwrap();
    assert!(!f.domain.retire_membership_loss_trusted(&binding.id, binding.generation, &joined, crate::api::now_ms()).await.unwrap());
    fake.member(&room, &f.p.mxid, "leave");
    let left = fake.gateway().room(&room, "", &f.p.mxid, Some(&puppet)).await.unwrap();
    assert!(f.domain.retire_membership_loss_trusted(&binding.id, binding.generation, &left, crate::api::now_ms()).await.unwrap(),
        "leaving again after the rejoin counts at once");
}

#[tokio::test]
#[ignore = "requires dedicated PostgreSQL database via HAGENCY_AGENT_TEST_DATABASE_URL"]
async fn postgres_unknown_invite_failure_keeps_the_room_and_a_refusal_replaces_it() {
    let (f, fake, room) = direct().await;
    fake.member(&room, &f.p.mxid, "leave");
    *fake.invite_fails.lock().unwrap() = Some(false);
    assert!(run(&f, &fake).await.is_err(), "an unknown outcome is reported, not replaced");
    assert!(fake.created.lock().unwrap().is_empty());
    *fake.invite_fails.lock().unwrap() = Some(true);
    let reply = run(&f, &fake).await.unwrap();
    assert_eq!(reply["outcome"], "replaced", "Matrix refused the puppet: only a new Room helps");
    assert_ne!(reply["ownerDirectRoomId"], json!(room));
}

#[tokio::test]
#[ignore = "requires dedicated PostgreSQL database via HAGENCY_AGENT_TEST_DATABASE_URL"]
async fn postgres_agent_gone_assigns_one_new_room_atomically() {
    let (f, fake, old) = direct().await;
    let puppet = f.facts.puppet_mxid.clone();
    fake.member(&old, &f.p.mxid, "leave");
    fake.member(&old, &puppet, "leave");
    fake.rooms.lock().unwrap().get_mut(&old).unwrap()
        .push(json!({"type":"m.room.encryption","state_key":"","content":{"algorithm":"m.megolm.v1.aes-sha2"}}));
    let reply = run(&f, &fake).await.unwrap();
    assert_eq!(reply["outcome"], "replaced");
    let new = reply["ownerDirectRoomId"].as_str().unwrap().to_owned();
    assert_eq!(*fake.created.lock().unwrap(), vec![new.clone()]);
    assert_eq!(*fake.encrypted.lock().unwrap(), vec![new.clone()], "an encrypted chat stays encrypted");
    assert_eq!(*fake.invites.lock().unwrap(), vec![(puppet.clone(), new.clone(), f.p.mxid.clone())], "the owner is invited after the swap");
    assert_ne!(new, old);
    let agent = f.domain.agent(&f.p, &f.agent, crate::api::now_ms()).await.unwrap();
    assert_eq!(agent.owner_direct_room_id.as_deref(), Some(new.as_str()), "exactly one current owner-direct Room");
    let bindings = direct_bindings(&f).await;
    let state = |room: &str| bindings.iter().find(|b| b.room_id == room).map(|b| b.state.clone());
    assert_eq!(state(&old).as_deref(), Some("leaving"), "the superseded binding departs");
    assert_eq!(state(&new).as_deref(), Some("joining"));
    // The superseded Room can never be swapped in again (compare-and-swap).
    assert!(matches!(
        f.domain.replace_owner_direct(&f.p, &f.agent, &old, "!other:example.test", crate::api::now_ms()).await,
        Err(Error::Conflict("owner_direct_room_changed"))
    ));
    // The owner's client joins; its usual adopt call returns the same binding.
    fake.member(&new, &f.p.mxid, "join");
    let facts = fake.gateway().room(&new, "", &f.p.mxid, Some(&puppet)).await.unwrap();
    let adopted = f.domain.adopt_owner_direct(&f.p, &f.agent, &new, &facts, crate::api::now_ms()).await.unwrap();
    assert_eq!(Some(adopted.binding.room_id.clone()), state(&new).map(|_| new.clone()));
    assert_eq!(run(&f, &fake).await.unwrap(), json!({"outcome":"joined","ownerDirectRoomId":new}));
}

#[tokio::test]
#[ignore = "requires dedicated PostgreSQL database via HAGENCY_AGENT_TEST_DATABASE_URL"]
async fn postgres_concurrent_recovery_creates_one_room() {
    let (f, fake, old) = direct().await;
    fake.member(&old, &f.p.mxid, "leave");
    fake.member(&old, &f.facts.puppet_mxid, "leave");
    let (a, b) = tokio::join!(run(&f, &fake), run(&f, &fake));
    let (a, b) = (a.unwrap(), b.unwrap());
    assert_eq!(fake.created.lock().unwrap().len(), 1, "one replacement Room");
    assert_eq!(a["ownerDirectRoomId"], b["ownerDirectRoomId"]);
    let mut outcomes = [a["outcome"].as_str().unwrap(), b["outcome"].as_str().unwrap()];
    outcomes.sort();
    assert_eq!(outcomes, ["invited", "replaced"]);
}

#[tokio::test]
#[ignore = "requires dedicated PostgreSQL database via HAGENCY_AGENT_TEST_DATABASE_URL"]
async fn postgres_only_the_owner_can_recover_and_nobody_else_is_invited() {
    let (f, fake, room) = direct().await;
    fake.member(&room, &f.p.mxid, "leave");
    let now = crate::api::now_ms();
    let suffix = crate::secret_token();
    let grant = f.auth.sign_in(Identity {
        issuer: "https://example.test/auth/".into(),
        subject: format!("stranger-{suffix}"),
        mxid: format!("@stranger_{suffix}:example.test"),
        client_id: "transport-client".into(),
        valid_until_ms: now + 1_000_000,
    }, now).await.unwrap();
    let device = f.auth.register_device(&grant.token, RegisterDevice { installation_id: "stranger".into(), name: "Stranger".into() }, now).await.unwrap();
    let stranger = f.auth.authenticate(&device.token, now, true).await.unwrap();
    assert!(recover(&f.domain, &fake.gateway(), &fake, &stranger, &f.agent, crate::api::now_ms).await.is_err());
    assert!(fake.invites.lock().unwrap().is_empty() && fake.created.lock().unwrap().is_empty());
    assert!(f.domain.replace_owner_direct(&stranger, &f.agent, &room, "!stolen:example.test", now).await.is_err());
    assert!(f.domain.begin_owner_rejoin(&stranger, &f.agent, &room, now).await.is_err());
}
