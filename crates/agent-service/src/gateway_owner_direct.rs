//! What an Agent's owner-direct Room can still do for its owner, read from the
//! same privileged state snapshot as every other gateway fact (ADR 0003).
use super::{content, joined, level, power_integer, power_object};
use crate::Result;
use serde_json::Value;

/// The owner's standing in the Agent's current owner-direct Room.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DirectRoom {
    /// Owner joined: nothing to recover.
    OwnerJoined,
    /// Owner holds an invitation already: the client only has to join.
    OwnerInvited,
    /// Owner left, was kicked or was never a member; the joined puppet may invite.
    Reinvitable,
    /// The Room cannot bring the owner back; the code says why.
    Unusable(&'static str),
}

/// Classifies one complete state snapshot of `room` for `owner` and `puppet`.
pub fn classify(state: &[Value], owner: &str, puppet: &str) -> Result<DirectRoom> {
    if content(state, "m.room.tombstone", "").is_some() {
        return Ok(DirectRoom::Unusable("owner_direct_room_upgraded"));
    }
    let private = content(state, "m.room.create", "").is_some_and(|c| c["type"] != "m.space")
        && content(state, "m.room.join_rules", "").is_some_and(|c| c["join_rule"] == "invite")
        && !content(state, "m.room.guest_access", "").is_some_and(|c| c["guest_access"] == "can_join")
        && content(state, "m.room.history_visibility", "")
            .is_some_and(|c| matches!(c["history_visibility"].as_str(), Some("joined" | "invited" | "shared")));
    if !private {
        return Ok(DirectRoom::Unusable("owner_direct_room_not_private"));
    }
    if !joined(state, puppet) {
        return Ok(DirectRoom::Unusable("owner_direct_agent_absent"));
    }
    let membership = content(state, "m.room.member", owner).and_then(|c| c["membership"].as_str());
    Ok(match membership {
        Some("join") => DirectRoom::OwnerJoined,
        Some("invite") => DirectRoom::OwnerInvited,
        Some("ban") => DirectRoom::Unusable("owner_direct_owner_banned"),
        _ => {
            let powers = content(state, "m.room.power_levels", "");
            let needed = power_integer(power_object(powers)?.and_then(|p| p.get("invite")), 0)?;
            if level(powers, puppet)? >= needed {
                DirectRoom::Reinvitable
            } else {
                DirectRoom::Unusable("owner_direct_invite_denied")
            }
        }
    })
}

impl super::Gateway {
    /// One read of `room`: the owner's standing and whether it is encrypted.
    /// A read failure is returned, never treated as an unusable Room, so a
    /// transient outage cannot replace a working chat.
    pub async fn owner_direct_room(&self, room: &str, owner: &str, puppet: &str) -> Result<(DirectRoom, bool)> {
        let state = self.state(room).await?;
        Ok((classify(&state, owner, puppet)?, content(&state, "m.room.encryption", "").is_some()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    const OWNER: &str = "@owner:test";
    const PUPPET: &str = "@_hagency_agent:test";
    fn room(owner: Option<&str>, puppet: &str) -> Vec<Value> {
        let mut state = vec![
            json!({"type":"m.room.create","state_key":"","content":{}}),
            json!({"type":"m.room.join_rules","state_key":"","content":{"join_rule":"invite"}}),
            json!({"type":"m.room.history_visibility","state_key":"","content":{"history_visibility":"joined"}}),
            json!({"type":"m.room.power_levels","state_key":"","content":{"users":{PUPPET:100},"invite":50}}),
            json!({"type":"m.room.member","state_key":PUPPET,"content":{"membership":puppet}}),
        ];
        if let Some(owner) = owner {
            state.push(json!({"type":"m.room.member","state_key":OWNER,"content":{"membership":owner}}));
        }
        state
    }
    #[test]
    fn owner_standing_decides_recovery() {
        assert_eq!(classify(&room(Some("join"), "join"), OWNER, PUPPET).unwrap(), DirectRoom::OwnerJoined);
        assert_eq!(classify(&room(Some("invite"), "join"), OWNER, PUPPET).unwrap(), DirectRoom::OwnerInvited);
        for left in [Some("leave"), None] {
            assert_eq!(classify(&room(left, "join"), OWNER, PUPPET).unwrap(), DirectRoom::Reinvitable, "{left:?}");
        }
        assert_eq!(classify(&room(Some("ban"), "join"), OWNER, PUPPET).unwrap(), DirectRoom::Unusable("owner_direct_owner_banned"));
    }
    #[test]
    fn a_room_without_the_agent_or_superseded_is_unusable() {
        for gone in ["leave", "invite", "ban"] {
            assert_eq!(classify(&room(Some("leave"), gone), OWNER, PUPPET).unwrap(), DirectRoom::Unusable("owner_direct_agent_absent"));
        }
        let mut upgraded = room(Some("leave"), "join");
        upgraded.push(json!({"type":"m.room.tombstone","state_key":"","content":{"replacement_room":"!new:test"}}));
        assert_eq!(classify(&upgraded, OWNER, PUPPET).unwrap(), DirectRoom::Unusable("owner_direct_room_upgraded"));
        let mut public = room(Some("leave"), "join");
        public[1]["content"]["join_rule"] = json!("public");
        assert_eq!(classify(&public, OWNER, PUPPET).unwrap(), DirectRoom::Unusable("owner_direct_room_not_private"));
        let mut readable = room(Some("leave"), "join");
        readable[2]["content"]["history_visibility"] = json!("world_readable");
        assert_eq!(classify(&readable, OWNER, PUPPET).unwrap(), DirectRoom::Unusable("owner_direct_room_not_private"));
        let mut weak = room(Some("leave"), "join");
        weak[3]["content"]["users"][PUPPET] = json!(0);
        assert_eq!(classify(&weak, OWNER, PUPPET).unwrap(), DirectRoom::Unusable("owner_direct_invite_denied"));
    }
}
