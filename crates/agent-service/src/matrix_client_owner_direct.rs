//! Owner-direct recovery as the Agent's own puppet (ADR 0003). The puppet only
//! ever invites the Agent's owner; the caller supplies no invitee.
use super::MatrixClient;
use crate::{Error, Result, domain::Agent};
use reqwest::Method;
use serde_json::{Value, json};

/// State event marking a Room as one Agent's private chat with its owner. The
/// desktop's owner-created rooms carry the same type and content shape.
pub(crate) const OWNER_DIRECT_MARKER: &str = "im.hagency.agent.owner_direct";

/// The createRoom body of a replacement owner-direct Room: invite-only, no
/// guests, history from join, the owner invited and as powerful as the puppet.
pub(crate) fn owner_direct_room(agent: &Agent, owner: &str) -> Value {
    json!({
        "preset": "private_chat",
        "visibility": "private",
        "is_direct": true,
        "name": agent.display_name,
        "invite": [owner],
        "power_level_content_override": {"users": {agent.puppet_mxid.as_str(): 100, owner: 100}},
        "initial_state": [
            {"type": "m.room.history_visibility", "state_key": "", "content": {"history_visibility": "joined"}},
            {"type": "m.room.guest_access", "state_key": "", "content": {"guest_access": "forbidden"}},
            {"type": "m.room.join_rules", "state_key": "", "content": {"join_rule": "invite"}},
            {"type": OWNER_DIRECT_MARKER, "state_key": "", "content": {"version": 1, "agentId": agent.id, "ownerMxid": owner}},
        ],
    })
}

impl MatrixClient {
    /// The puppet invites its owner back into the Agent's owner-direct Room.
    pub(crate) async fn invite_owner(&self, puppet: &str, room: &str, owner: &str) -> Result<()> {
        self.call(Method::POST, &["_matrix", "client", "v3", "rooms", room, "invite"], puppet, Some(json!({"user_id": owner})))
            .await?;
        Ok(())
    }
    /// The puppet creates a replacement owner-direct Room and invites the owner.
    pub(crate) async fn create_owner_direct(&self, agent: &Agent, owner: &str) -> Result<String> {
        let created = self
            .call(Method::POST, &["_matrix", "client", "v3", "createRoom"], &agent.puppet_mxid, Some(owner_direct_room(agent, owner)))
            .await?;
        created["room_id"]
            .as_str()
            .filter(|r| r.starts_with('!'))
            .map(str::to_owned)
            .ok_or(Error::Unavailable("invalid_matrix_response"))
    }
}
