//! Readable Agent IDs (ADR 0002) widened the reserved user namespace. This
//! upgrades a legacy registration in place and refuses to reserve accounts
//! that people already hold.
use super::ID;
use diesel::sql_types::Text;
use diesel_async::RunQueryDsl;
use serde_json::json;
use std::{collections::BTreeSet, io::Write, path::Path};

/// Agent puppet localparts after `_hagency_`: `agt_<ulid>` and readable
/// `<owner>_<name>[-N]`. `-` joined the class with readable IDs.
pub(super) const USER_LOCALPART: &str = "[a-z0-9_-]+";
/// The class every registration persisted before readable IDs carries.
pub(super) const LEGACY_USER_LOCALPART: &str = "[a-z0-9_]+";

pub(super) fn users_regex(server: &str, class: &str) -> String {
    format!("^@_hagency_{class}:{}$", regex::escape(server))
}
pub(super) fn is_legacy(registration: &palpo::core::appservice::Registration, server: &str) -> anyhow::Result<bool> {
    let value = serde_json::to_value(registration)?;
    Ok(value["namespaces"]["users"][0]["regex"] == users_regex(server, LEGACY_USER_LOCALPART))
}
pub(super) fn with_users_regex(
    registration: &palpo::core::appservice::Registration,
    regex: &str,
) -> anyhow::Result<palpo::core::appservice::Registration> {
    let mut value = serde_json::to_value(registration)?;
    if let Some(users) = value["namespaces"]["users"].as_array_mut()
        && users.len() == 1
    {
        users[0]["regex"] = json!(regex);
    }
    Ok(serde_json::from_value(value)?)
}

/// Accounts the widened namespace newly claims (they match it, not the legacy
/// one) that are neither the service nor a recorded Agent puppet: a person
/// registered them, so reserving would hand them to this Appservice. Legacy
/// names were already reserved, so a leftover one never blocks startup.
pub(super) fn blocking_accounts<'a>(
    accounts: impl Iterator<Item = &'a str>,
    puppets: &BTreeSet<String>,
    server: &str,
) -> Vec<String> {
    let (Ok(now), Ok(before)) = (
        regex::Regex::new(&users_regex(server, USER_LOCALPART)),
        regex::Regex::new(&users_regex(server, LEGACY_USER_LOCALPART)),
    ) else {
        return vec!["<invalid namespace regex>".into()];
    };
    accounts
        .filter(|u| now.is_match(u) && !before.is_match(u) && !puppets.contains(*u))
        .map(str::to_owned)
        .collect()
}

#[derive(diesel::QueryableByName)]
struct Id {
    #[diesel(sql_type = Text)]
    id: String,
}
#[derive(diesel::QueryableByName)]
struct Present {
    #[diesel(sql_type = diesel::sql_types::Bool)]
    present: bool,
}

/// One read of every `_hagency_` account on this server and of every
/// recorded puppet (none before the Agent schema exists).
pub(super) async fn unclaimed_accounts(server: &str) -> anyhow::Result<Vec<String>> {
    let mut conn = palpo::data::connect().await?;
    let accounts = diesel::sql_query("SELECT id FROM users WHERE server_name=$1 AND left(localpart,9)='_hagency_'")
        .bind::<Text, _>(server)
        .load::<Id>(&mut *conn)
        .await?;
    let schema = diesel::sql_query("SELECT to_regclass('hagency_agent_v1.agents') IS NOT NULL AS present")
        .get_result::<Present>(&mut *conn)
        .await?;
    let puppets: BTreeSet<String> = if schema.present {
        diesel::sql_query("SELECT puppet_mxid AS id FROM hagency_agent_v1.agents")
            .load::<Id>(&mut *conn)
            .await?
            .into_iter()
            .map(|r| r.id)
            .collect()
    } else {
        BTreeSet::new()
    };
    Ok(blocking_accounts(accounts.iter().map(|a| a.id.as_str()), &puppets, server))
}

/// Widens Palpo's row in one conditional UPDATE: the reservation is never
/// absent, and tokens and the disabled flag stay as they are.
pub(super) async fn widen_row(server: &str) -> anyhow::Result<()> {
    let mut conn = palpo::data::connect().await?;
    let updated = diesel::sql_query(
        "UPDATE appservice_registrations SET namespaces=jsonb_set(namespaces::jsonb,'{users,0,regex}',to_jsonb($2::text))::json \
         WHERE id=$1 AND jsonb_array_length(namespaces::jsonb->'users')=1 AND namespaces::jsonb->'users'->0->>'regex'=$3",
    )
    .bind::<Text, _>(ID)
    .bind::<Text, _>(users_regex(server, USER_LOCALPART))
    .bind::<Text, _>(users_regex(server, LEGACY_USER_LOCALPART))
    .execute(&mut *conn)
    .await?;
    anyhow::ensure!(updated == 1, "Agent Appservice registration changed during the namespace upgrade");
    Ok(())
}

/// Replaces the credential file atomically; the tokens are unchanged.
pub(super) fn persist_upgrade(path: &Path, registration: &palpo::core::appservice::Registration) -> anyhow::Result<()> {
    let dir = path.parent().ok_or_else(|| anyhow::anyhow!("missing Appservice directory"))?;
    let mut file = tempfile::NamedTempFile::new_in(dir)?;
    file.write_all(&serde_json::to_vec(registration)?)?;
    file.as_file().sync_all()?;
    file.persist(path).map_err(|e| e.error)?;
    std::fs::File::open(dir)?.sync_all()?;
    Ok(())
}
