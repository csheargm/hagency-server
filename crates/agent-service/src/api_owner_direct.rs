//! `POST /agents/{id}/owner-direct/recover` (ADR 0003): brings the owner back
//! into the Agent's private chat. The puppet re-invites the owner while it is
//! still in the Room; otherwise a replacement Room is created and swapped in.
//! Only the Agent's owner is ever invited, and only by its own puppet.
use crate::{
    Error, Result,
    domain::{Agent, DomainStore},
    gateway::{DirectRoom, Gateway},
    matrix_client::MatrixClient,
    store::Principal,
};
use serde_json::{Value, json};
use std::{collections::HashMap, future::Future, sync::{Arc, LazyLock, Mutex as StdMutex}};

/// One recovery at a time per Agent in this process: a concurrent second call
/// observes the first call's outcome instead of creating a second Room. Across
/// processes the domain's compare-and-swap keeps one current Room.
static RECOVERING: LazyLock<StdMutex<HashMap<String, Arc<tokio::sync::Mutex<()>>>>> = LazyLock::new(Default::default);
fn agent_lock(agent: &str) -> Arc<tokio::sync::Mutex<()>> {
    // A poisoned map only means another recovery panicked; its entries stay valid.
    let mut locks = RECOVERING.lock().unwrap_or_else(|e| e.into_inner());
    locks.entry(agent.to_owned()).or_default().clone()
}

/// The puppet operations recovery needs; tests supply a recording fake.
pub(crate) trait DirectMatrix: Sync {
    fn invite_owner(&self, puppet: &str, room: &str, owner: &str) -> impl Future<Output = Result<()>> + Send;
    fn create_owner_direct(&self, agent: &Agent, owner: &str, encrypted: bool) -> impl Future<Output = Result<String>> + Send;
    fn leave(&self, puppet: &str, room: &str) -> impl Future<Output = Result<()>> + Send;
}
impl DirectMatrix for MatrixClient {
    fn invite_owner(&self, puppet: &str, room: &str, owner: &str) -> impl Future<Output = Result<()>> + Send {
        MatrixClient::invite_owner(self, puppet, room, owner)
    }
    fn create_owner_direct(&self, agent: &Agent, owner: &str, encrypted: bool) -> impl Future<Output = Result<String>> + Send {
        MatrixClient::create_owner_direct(self, agent, owner, encrypted)
    }
    fn leave(&self, puppet: &str, room: &str) -> impl Future<Output = Result<()>> + Send {
        MatrixClient::leave(self, puppet, room)
    }
}

fn outcome(outcome: &str, room: Option<&str>) -> Value {
    json!({"outcome": outcome, "ownerDirectRoomId": room})
}

/// Outcomes: `none` (no Room yet: the client creates one), `joined` (nothing
/// to do), `invited` (an invitation is waiting), `reinvited` (same Room) and
/// `replaced` (new Room). After the last three the owner's client joins.
pub(crate) async fn recover<M: DirectMatrix>(
    domain: &DomainStore,
    gateway: &Gateway,
    matrix: &M,
    p: &Principal,
    agent: &str,
    now: impl Fn() -> i64,
) -> Result<Value> {
    let lock = agent_lock(agent);
    let _serial = lock.lock().await;
    let (a, binding) = domain.owner_direct_current(p, agent, now()).await?;
    let Some(room) = a.owner_direct_room_id.clone() else { return Ok(outcome("none", None)) };
    let state = binding.as_ref().map(|b| b.state.as_str()).unwrap_or("");
    let live = matches!(state, "joining" | "active" | "suspended");
    // A leaving or revoked binding means the puppet is departing: the Room no
    // longer serves the owner even if they are still in it.
    let retired = matches!(state, "leaving" | "revoked");
    let (standing, encrypted) = gateway.owner_direct_room(&room, &p.mxid, &a.puppet_mxid).await?;
    match standing {
        // The owner can use the Room; the client's adopt call rebinds a left binding.
        DirectRoom::OwnerJoined if !retired => return Ok(outcome("joined", Some(&room))),
        DirectRoom::OwnerInvited if !retired => return Ok(outcome("invited", Some(&room))),
        DirectRoom::Reinvitable if live => {
            domain.begin_owner_rejoin(p, agent, &room, now()).await?;
            match matrix.invite_owner(&a.puppet_mxid, &room, &p.mxid).await {
                Ok(()) => return Ok(outcome("reinvited", Some(&room))),
                // Matrix refused the puppet (power or membership changed since
                // the snapshot): a replacement Room is the only way back.
                Err(Error::Conflict("matrix_permission_missing")) => {}
                // Unknown or transient: the invitation may even have landed.
                // Keep the Room; the next call re-reads its membership.
                Err(e) => return Err(e),
            }
        }
        _ => {}
    }
    // Created without an invitation: the owner is invited only once the swap
    // committed, so a refused swap never leaves an invitation behind.
    let created = matrix.create_owner_direct(&a, &p.mxid, encrypted).await?;
    if let Err(e) = domain.replace_owner_direct(p, agent, &room, &created, now()).await {
        // The commit may have landed with its reply lost: never leave the Room
        // the Agent now points at.
        let current = domain.owner_direct_current(p, agent, now()).await.ok().and_then(|(a, _)| a.owner_direct_room_id);
        if current.as_deref() != Some(created.as_str()) {
            // Nothing refers to the new Room. A failed leave only strands an
            // empty Room nobody is invited to; the refusal is what matters.
            let _ = matrix.leave(&a.puppet_mxid, &created).await;
            return Err(e);
        }
    }
    // If this invite fails, the binding is live and the puppet joined, so the
    // next call classifies the Room as reinvitable and invites again.
    matrix.invite_owner(&a.puppet_mxid, &created, &p.mxid).await?;
    Ok(outcome("replaced", Some(&created)))
}

/// Route guard shared with `api.rs`: recovery needs the Appservice client.
pub(crate) fn require_matrix(matrix: Option<&MatrixClient>) -> Result<&MatrixClient> {
    matrix.ok_or(Error::Unavailable("matrix_unavailable"))
}
