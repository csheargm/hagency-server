//! Hagency-owned profile fields (MSC4133) of an Agent puppet, written only
//! through the Appservice. The homeserver refuses `io.hagency.*` writes from
//! anyone else (palpo `profile_reserved.rs`), so a reader can trust that the
//! owner field was set by this server, not claimed by a device.
use super::*;

/// The profile field naming the Agent's owner. Same name the desktop reads
/// (hagency-core `agent_owner::OWNER_FIELD`).
pub const OWNER_FIELD: &str = "io.hagency.owner";
/// The profile field naming the runtime an Agent runs on (e.g. `claude`).
pub const RUNTIME_FIELD: &str = "io.hagency.runtime";

impl MatrixClient {
    /// Publishes `owner` (and `runtime`, when known) on the puppet's profile.
    pub(crate) async fn set_agent_fields(&self, puppet: &str, owner: &str, runtime: Option<&str>) -> Result<()> {
        self.set_profile_field(puppet, OWNER_FIELD, owner).await?;
        if let Some(runtime) = runtime {
            self.set_profile_field(puppet, RUNTIME_FIELD, runtime).await?;
        }
        Ok(())
    }
    /// Sets the owner field unless the puppet's profile already says `owner`,
    /// so a restart re-checks every Agent without a profile write each.
    pub(crate) async fn ensure_owner_field(&self, puppet: &str, owner: &str) -> Result<()> {
        let path = ["_matrix", "client", "v3", "profile", puppet, OWNER_FIELD];
        // A missing field answers 404, which `request` reports like any other
        // failure; either way the PUT below decides the outcome.
        if let Ok(current) = self.read_as(puppet, &path, &[]).await {
            if current[OWNER_FIELD] == owner {
                return Ok(());
            }
        }
        self.set_profile_field(puppet, OWNER_FIELD, owner).await
    }
    async fn set_profile_field(&self, puppet: &str, field: &str, value: &str) -> Result<()> {
        let path = ["_matrix", "client", "v3", "profile", puppet, field];
        self.call(Method::PUT, &path, puppet, Some(json!({ field: value }))).await?;
        Ok(())
    }
}

#[cfg(test)]
#[path = "matrix_client_profile_fields_tests.rs"]
mod tests;
