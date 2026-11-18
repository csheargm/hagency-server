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
use std::future::Future;

/// One recovery at a time in this process: a concurrent second call observes
/// the first call's outcome instead of creating a second replacement Room.
/// Across processes the domain's compare-and-swap keeps one current Room.
static RECOVERY: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// The puppet operations recovery needs; tests supply a recording fake.
pub(crate) trait DirectMatrix: Sync {
    fn invite_owner(&self, puppet: &str, room: &str, owner: &str) -> impl Future<Output = Result<()>> + Send;
    fn create_owner_direct(&self, agent: &Agent, owner: &str) -> impl Future<Output = Result<String>> + Send;
    fn leave(&self, puppet: &str, room: &str) -> impl Future<Output = Result<()>> + Send;
}
impl DirectMatrix for MatrixClient {
    fn invite_owner(&self, puppet: &str, room: &str, owner: &str) -> impl Future<Output = Result<()>> + Send {
        MatrixClient::invite_owner(self, puppet, room, owner)
    }
    fn create_owner_direct(&self, agent: &Agent, owner: &str) -> impl Future<Output = Result<String>> + Send {
        MatrixClient::create_owner_direct(self, agent, owner)
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
    let _serial = RECOVERY.lock().await;
    let (a, binding) = domain.owner_direct_current(p, agent, now()).await?;
    let Some(room) = a.owner_direct_room_id.clone() else { return Ok(outcome("none", None)) };
    let state = binding.as_ref().map(|b| b.state.as_str()).unwrap_or("");
    let live = matches!(state, "joining" | "active" | "suspended");
    match gateway.owner_direct_room(&room, &p.mxid, &a.puppet_mxid).await? {
        // The owner can use the Room; the client's adopt call rebinds a left binding.
        DirectRoom::OwnerJoined => return Ok(outcome("joined", Some(&room))),
        DirectRoom::OwnerInvited if !matches!(state, "leaving" | "revoked") => {
            return Ok(outcome("invited", Some(&room)));
        }
        DirectRoom::Reinvitable if live => {
            domain.begin_owner_rejoin(p, agent, &room, now()).await?;
            if matrix.invite_owner(&a.puppet_mxid, &room, &p.mxid).await.is_ok() {
                return Ok(outcome("reinvited", Some(&room)));
            }
            // The puppet could not invite after all (power or membership changed
            // since the snapshot): a replacement Room is the only way back.
        }
        // A retired binding means the puppet is leaving or has left: inviting
        // the owner would land them in a Room the Agent no longer serves.
        _ => {}
    }
    let created = matrix.create_owner_direct(&a, &p.mxid).await?;
    match domain.replace_owner_direct(p, agent, &room, &created, now()).await {
        Ok(_) => Ok(outcome("replaced", Some(&created))),
        Err(e) => {
            // The swap was refused, so nothing refers to the new Room: the
            // puppet leaves it. A failed leave only strands an empty, unused
            // Room, and the refusal below is what the owner needs to see.
            let _ = matrix.leave(&a.puppet_mxid, &created).await;
            Err(e)
        }
    }
}

/// Route guard shared with `api.rs`: recovery needs the Appservice client.
pub(crate) fn require_matrix(matrix: Option<&MatrixClient>) -> Result<&MatrixClient> {
    matrix.ok_or(Error::Unavailable("matrix_unavailable"))
}
