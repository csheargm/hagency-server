//! Owner-only recovery of an Agent's private chat after its owner left it
//! (ADR 0003). The Agent keeps exactly one current owner-direct Room; it is
//! replaced only here, by compare-and-swap on the Room it supersedes.
use super::*;

/// How long an owner-direct binding outlives its owner's absence after a
/// recovery invitation, so the reconciler does not retire it before the
/// owner's client accepts. Afterwards ordinary membership loss applies.
pub const OWNER_REJOIN_GRACE_MS: i64 = 120_000;
const BINDING_COLUMNS: &str = "id,agent_id,project_id,room_id,state,generation,scope_kind,owner_service_paused,thread_auto_reply";

impl DomainStore {
    /// The owner's active Agent and the binding of its current owner-direct Room.
    pub async fn owner_direct_current(&self, p: &Principal, agent: &str, now: i64) -> Result<(Agent, Option<Binding>)> {
        let mut db = self.db.lock().await?;
        (*db).transaction::<_, Error, _>(async |db: &mut AsyncPgConnection| {
            Self::authorize(db, p, now).await?;
            let a = Self::recoverable_agent(db, p, agent).await?;
            let binding = match &a.owner_direct_room_id {
                Some(room) => Self::direct_binding(db, agent, room).await?,
                None => None,
            };
            Ok((a, binding))
        }).await
    }

    /// Before the puppet re-invites the owner: the Room must still be current
    /// and its binding live. Opens the rejoin grace in the same transaction, so
    /// a reconciler pass cannot retire the binding between invite and join.
    pub async fn begin_owner_rejoin(&self, p: &Principal, agent: &str, room: &str, now: i64) -> Result<Binding> {
        let mut db = self.db.lock().await?;
        (*db).transaction::<_, Error, _>(async |db: &mut AsyncPgConnection| {
            Self::authorize(db, p, now).await?;
            let a = Self::recoverable_agent(db, p, agent).await?;
            if a.owner_direct_room_id.as_deref() != Some(room) {
                return Err(Error::Conflict("owner_direct_room_changed"));
            }
            let binding = Self::direct_binding(db, agent, room).await?
                .filter(|b| matches!(b.state.as_str(), "joining" | "active" | "suspended"))
                .ok_or(Error::Conflict("owner_direct_binding_inactive"))?;
            sql_query("UPDATE hagency_agent_v1.bindings SET owner_rejoin_until_ms=$2 WHERE id=$1")
                .bind::<Text, _>(&binding.id).bind::<BigInt, _>(now + OWNER_REJOIN_GRACE_MS).execute(db).await?;
            Self::audit(db, p, "agent.owner_direct.reinvite", &binding.id, now).await?;
            Ok(binding)
        }).await
    }

    /// Atomically makes `room` (created by the puppet, owner invited) the
    /// Agent's only owner-direct Room, if `previous` is still current. The old
    /// binding starts leaving; the new one joins within the rejoin grace.
    pub async fn replace_owner_direct(&self, p: &Principal, agent: &str, previous: &str, room: &str, now: i64) -> Result<AgentBinding> {
        matrix_id(room, '!')?;
        if room == previous {
            return Err(Error::Invalid("owner_direct_room_unchanged"));
        }
        let mut db = self.db.lock().await?;
        (*db).transaction::<_, Error, _>(async |db: &mut AsyncPgConnection| {
            Self::authorize(db, p, now).await?;
            let a = Self::recoverable_agent(db, p, agent).await?;
            if a.owner_direct_room_id.as_deref() != Some(previous) {
                return Err(Error::Conflict("owner_direct_room_changed"));
            }
            sql_query("UPDATE hagency_agent_v1.bindings SET state='leaving',generation=generation+1 WHERE agent_id=$1 AND room_id=$2 AND scope_kind='owner_direct' AND state IN ('joining','active','suspended')")
                .bind::<Text, _>(agent).bind::<Text, _>(previous).execute(db).await?;
            sql_query("SELECT set_config('hagency_agent_v1.owner_direct_replaces',$1,true)").bind::<Text, _>(previous).execute(db).await?;
            let a = sql_query("UPDATE hagency_agent_v1.agents SET owner_direct_room_id=$2 WHERE id=$1 RETURNING id,owner_user_id,puppet_mxid,display_name,state,generation,owner_direct_room_id,execution_device_id,visibility")
                .bind::<Text, _>(agent).bind::<Text, _>(room).get_result::<Agent>(db).await?;
            sql_query("SELECT set_config('hagency_agent_v1.owner_direct_replaces','',true)").execute(db).await?;
            let binding = sql_query(format!("INSERT INTO hagency_agent_v1.bindings(id,agent_id,project_id,room_id,state,scope_kind,owner_rejoin_until_ms) VALUES($1,$2,NULL,$3,'joining','owner_direct',$4) RETURNING {BINDING_COLUMNS}"))
                .bind::<Text, _>(format!("bnd_{}", entity_id()?)).bind::<Text, _>(agent).bind::<Text, _>(room)
                .bind::<BigInt, _>(now + OWNER_REJOIN_GRACE_MS).get_result::<Binding>(db).await?;
            Self::audit(db, p, "agent.owner_direct.replace", agent, now).await?;
            Ok(AgentBinding { agent: a, binding })
        }).await
    }

    async fn recoverable_agent(db: &mut AsyncPgConnection, p: &Principal, agent: &str) -> Result<Agent> {
        let a = Self::agent_db(db, p, agent).await?;
        if a.state != "active" {
            return Err(Error::Conflict("agent_identity_not_active"));
        }
        Ok(a)
    }

    async fn direct_binding(db: &mut AsyncPgConnection, agent: &str, room: &str) -> Result<Option<Binding>> {
        Ok(sql_query(format!("SELECT {BINDING_COLUMNS} FROM hagency_agent_v1.bindings WHERE agent_id=$1 AND room_id=$2 AND scope_kind='owner_direct'"))
            .bind::<Text, _>(agent).bind::<Text, _>(room).get_result::<Binding>(db).await.optional()?)
    }
}
