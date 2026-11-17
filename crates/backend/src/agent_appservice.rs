//! Mandatory service-level registration for the integrated Agent product.
//! Uses Palpo's existing registration API; no per-user service installation.
use crate::config::Config;
use serde_json::json;
use std::{
    fs::{self, OpenOptions},
    io::{Read, Write},
    path::Path,
};

const ID: &str = "hagency_agents_v1";

pub async fn prepare(conf: &Config) -> anyhow::Result<palpo::core::appservice::Registration> {
    let server = conf.matrix.server_name.as_str();
    let path = conf.data_dir.join("agent-appservice.json");
    let mut registration = load_or_create(&path, server, conf.internal_origin().as_str())?;
    let existing = palpo::appservice::get_registration(ID).await?;
    let legacy_file = is_legacy(&registration, server)?;
    let legacy_row = match &existing {
        Some(row) => is_legacy(row, server)?,
        None => false,
    };
    if legacy_file || legacy_row {
        // Widening the namespace must not adopt an account a person already holds.
        let accounts = namespace_accounts(server).await?;
        let held = newly_reserved(accounts.iter().map(String::as_str), server);
        anyhow::ensure!(
            held.is_empty(),
            "Agent namespace upgrade blocked: existing accounts {held:?} would become reserved"
        );
    }
    if legacy_file {
        registration = with_users_regex(&registration, &users_regex(server, USER_LOCALPART))?;
        persist_upgrade(&path, &registration)?;
    }
    match existing {
        Some(existing) => {
            let disabled = palpo::appservice::list_all_registrations()
                .await?
                .iter()
                .find(|(r, _)| r.id == ID)
                .is_some_and(|(_, disabled)| *disabled);
            anyhow::ensure!(!disabled, "Agent Appservice is disabled");
            let same_identity = if legacy_row {
                with_users_regex(&existing, &users_regex(server, USER_LOCALPART))?
            } else {
                existing
            };
            anyhow::ensure!(
                serde_json::to_value(&same_identity)? == serde_json::to_value(&registration)?,
                "Agent Appservice registration conflicts with persisted deployment identity"
            );
            if legacy_row {
                // Palpo reads registrations from its table on each lookup; a
                // crash between these two calls re-registers on the next start.
                palpo::appservice::unregister_appservice(ID).await?;
                palpo::appservice::register_appservice(registration.clone()).await?;
            }
        }
        None => {
            palpo::appservice::register_appservice(registration.clone()).await?;
        }
    }
    Ok(registration)
}
/// Agent puppet localparts after `_hagency_`: `agt_<ulid>` and readable
/// `<owner>_<name>[-N]` (ADR 0002). `-` joined the class with readable IDs.
const USER_LOCALPART: &str = "[a-z0-9_-]+";
/// The class every registration persisted before readable IDs carries.
const LEGACY_USER_LOCALPART: &str = "[a-z0-9_]+";
fn users_regex(server: &str, class: &str) -> String {
    format!("^@_hagency_{class}:{}$", regex::escape(server))
}
fn is_legacy(registration: &palpo::core::appservice::Registration, server: &str) -> anyhow::Result<bool> {
    let value = serde_json::to_value(registration)?;
    Ok(value["namespaces"]["users"][0]["regex"] == users_regex(server, LEGACY_USER_LOCALPART))
}
fn with_users_regex(
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
/// Local accounts the widened namespace would newly claim: they match it but
/// not the legacy one, so a person (not this Appservice) registered them.
fn newly_reserved<'a>(users: impl Iterator<Item = &'a str>, server: &str) -> Vec<String> {
    let (Ok(now), Ok(before)) = (
        regex::Regex::new(&users_regex(server, USER_LOCALPART)),
        regex::Regex::new(&users_regex(server, LEGACY_USER_LOCALPART)),
    ) else {
        return vec!["<invalid namespace regex>".into()];
    };
    users.filter(|u| now.is_match(u) && !before.is_match(u)).map(str::to_owned).collect()
}
/// Every account on this server whose localpart contains `_hagency_`.
async fn namespace_accounts(server: &str) -> anyhow::Result<Vec<String>> {
    const PAGE: i64 = 1000;
    let mut found = Vec::new();
    loop {
        let filter = palpo::data::user::ListUsersFilter {
            server_name: Some(server.into()),
            name: Some("_hagency_".into()),
            from: Some(found.len() as i64),
            limit: Some(PAGE),
            order_by: Some("name".into()),
            ..Default::default()
        };
        let (page, total) = palpo::data::user::list_users(&filter).await?;
        let fetched = page.len();
        found.extend(page.into_iter().map(|u| u.id.to_string()));
        if fetched == 0 || found.len() as i64 >= total {
            return Ok(found);
        }
    }
}
/// Replaces the credential file atomically; the tokens are unchanged.
fn persist_upgrade(path: &Path, registration: &palpo::core::appservice::Registration) -> anyhow::Result<()> {
    let dir = path.parent().ok_or_else(|| anyhow::anyhow!("missing Appservice directory"))?;
    let mut file = tempfile::NamedTempFile::new_in(dir)?;
    file.write_all(&serde_json::to_vec(registration)?)?;
    file.as_file().sync_all()?;
    file.persist(path).map_err(|e| e.error)?;
    std::fs::File::open(dir)?.sync_all()?;
    Ok(())
}
fn load_or_create(
    path: &Path,
    server: &str,
    callback: &str,
) -> anyhow::Result<palpo::core::appservice::Registration> {
    fs::create_dir_all(
        path.parent()
            .ok_or_else(|| anyhow::anyhow!("missing Appservice directory"))?,
    )?;
    if !path.try_exists()? {
        // Never expose a partially written final credential file. A competing
        // initializer wins by atomic no-clobber persist, then both read it.
        let mut file = tempfile::NamedTempFile::new_in(path.parent().unwrap())?;
        let body = json!({"id":ID,"url":callback.trim_end_matches('/'),
                "as_token":hex::encode(rand::random::<[u8;32]>()),
                "hs_token":hex::encode(rand::random::<[u8;32]>()),
                "sender_localpart":"_hagency_service",
                "namespaces":{"users":[{"exclusive":true,"regex":users_regex(server, USER_LOCALPART)}],"aliases":[],"rooms":[]},
                "rate_limited":true,"receive_ephemeral":false});
        file.write_all(&serde_json::to_vec(&body)?)?;
        file.as_file().sync_all()?;
        match file.persist_noclobber(path) {
            Ok(_) => {
                std::fs::File::open(path.parent().unwrap())?.sync_all()?;
            }
            Err(error) if error.error.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error.error.into()),
        }
    }
    // Refuse symlinks and broadly readable secret files before reading credentials.
    let meta = fs::symlink_metadata(path)?;
    anyhow::ensure!(
        meta.is_file() && !meta.file_type().is_symlink(),
        "Appservice credentials must be a regular private file"
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        anyhow::ensure!(
            meta.permissions().mode() & 0o077 == 0,
            "Appservice credential permissions must be owner-only"
        );
    }
    anyhow::ensure!(
        meta.len() <= 16384,
        "Appservice credentials exceed size limit"
    );
    let mut raw = Vec::new();
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW);
    }
    let file = options.open(path)?;
    let actual = file.metadata()?;
    anyhow::ensure!(
        actual.is_file() && actual.len() <= 16384,
        "Appservice credentials must be a bounded regular file"
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        anyhow::ensure!(
            actual.permissions().mode() & 0o077 == 0,
            "Appservice credentials must remain owner-only"
        );
    }
    file.take(16385).read_to_end(&mut raw)?;
    let registration: palpo::core::appservice::Registration = serde_json::from_slice(&raw)?;
    let value = serde_json::to_value(&registration)?;
    let regex_ok = [USER_LOCALPART, LEGACY_USER_LOCALPART].iter().any(|class| {
        value["namespaces"]["users"] == json!([{"exclusive":true,"regex":users_regex(server, class)}])
    });
    anyhow::ensure!(
        registration.id == ID
            && registration.as_token.len() == 64
            && registration.hs_token.len() == 64
            && registration.url.as_deref() == Some(callback.trim_end_matches('/'))
            && registration.sender_localpart == "_hagency_service"
            && regex_ok
            && value["namespaces"]["aliases"]
                .as_array()
                .is_none_or(|v| v.is_empty())
            && value["namespaces"]["rooms"]
                .as_array()
                .is_none_or(|v| v.is_empty()),
        "Appservice credentials belong to another deployment or namespace"
    );
    Ok(registration)
}
/// Palpo's state reader skips PDUs it cannot load. Authorization requires every
/// event from the same immutable state frame, not a silently incomplete subset.
pub fn validate_state_completeness(
    expected: &[String],
    events: &[serde_json::Value],
) -> hagency_agent_service::Result<()> {
    let expected_count = expected.len();
    let expected = expected
        .iter()
        .map(String::as_str)
        .collect::<std::collections::BTreeSet<_>>();
    let actual = events
        .iter()
        .map(|event| event["event_id"].as_str())
        .collect::<Option<std::collections::BTreeSet<_>>>();
    if expected.len() != expected_count
        || actual
            .as_ref()
            .is_none_or(|actual| actual.len() != events.len() || actual != &expected)
    {
        return Err(hagency_agent_service::Error::Unavailable(
            "matrix_state_incomplete",
        ));
    }
    Ok(())
}
#[cfg(test)]
#[path = "agent_appservice_tests.rs"]
mod readable_id_tests;
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn registration_identity_survives_restart_and_rejects_moved_deployment() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("agent-appservice.json");
        let a = load_or_create(&path, "example.test", "http://127.0.0.1:8088/").unwrap();
        let b = load_or_create(&path, "example.test", "http://127.0.0.1:8088/").unwrap();
        assert_eq!(a.as_token, b.as_token);
        assert_eq!(a.hs_token, b.hs_token);
        assert_ne!(a.as_token, a.hs_token);
        assert!(load_or_create(&path, "another.test", "http://127.0.0.1:8088/").is_err());
        assert!(load_or_create(&path, "example.test", "http://127.0.0.1:9090/").is_err());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
            assert!(load_or_create(&path, "example.test", "http://127.0.0.1:8088/").is_err());
        }
    }
    #[test]
    fn authorization_rejects_partial_duplicate_or_wrong_state_frame_events() {
        let expected = vec!["$member".into(), "$powers".into(), "$encryption".into()];
        let complete = vec![
            json!({"event_id":"$encryption"}),
            json!({"event_id":"$member"}),
            json!({"event_id":"$powers"}),
        ];
        assert!(validate_state_completeness(&expected, &complete).is_ok());
        assert!(validate_state_completeness(&expected, &complete[..2]).is_err());
        let duplicate = vec![
            complete[0].clone(),
            complete[0].clone(),
            complete[1].clone(),
        ];
        assert!(validate_state_completeness(&expected, &duplicate).is_err());
        let wrong = vec![
            complete[0].clone(),
            complete[1].clone(),
            json!({"event_id":"$other-frame"}),
        ];
        assert!(validate_state_completeness(&expected, &wrong).is_err());
        assert!(validate_state_completeness(&expected, &[json!({"content":{}})]).is_err());
    }
}
