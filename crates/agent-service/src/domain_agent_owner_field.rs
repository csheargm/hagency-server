//! Which person each Agent puppet's `io.hagency.owner` profile field names:
//! the Agent's stored owner (the creating person, or a shared Agent's manager).
use super::*;

#[derive(Clone, Debug, PartialEq, Eq, diesel::QueryableByName)]
pub struct OwnerField {
    #[diesel(sql_type = Text)]
    pub id: String,
    #[diesel(sql_type = Text)]
    pub puppet_mxid: String,
    #[diesel(sql_type = Text)]
    pub owner_mxid: String,
}

#[derive(diesel::QueryableByName)]
struct OwnerMxid {
    #[diesel(sql_type = Text)]
    mxid: String,
}

impl DomainStore {
    /// The Matrix ID of `agent`'s owner.
    pub(crate) async fn agent_owner_mxid(&self, agent: &Agent) -> Result<String> {
        let mut db = self.db.lock().await?;
        let row: OwnerMxid = sql_query("SELECT mxid FROM hagency_agent_v1.users WHERE id=$1")
            .bind::<Text, _>(&agent.owner_user_id).get_result(&mut *db).await.map_err(hidden)?;
        Ok(row.mxid)
    }
    /// Live Agents after `after` in id order, each with its owner's Matrix ID.
    pub(crate) async fn owner_field_candidates(&self, after: &str, limit: i64) -> Result<Vec<OwnerField>> {
        let mut db = self.db.lock().await?;
        Ok(sql_query("SELECT a.id,a.puppet_mxid,u.mxid AS owner_mxid FROM hagency_agent_v1.agents a JOIN hagency_agent_v1.users u ON u.id=a.owner_user_id WHERE a.id>$1 AND a.state IN ('active','suspended') ORDER BY a.id LIMIT $2")
            .bind::<Text, _>(after).bind::<BigInt, _>(limit.clamp(1, 20)).load(&mut *db).await?)
    }
}
