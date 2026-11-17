//! Readable Agent IDs (ADR 0002): the reserved namespace covers both puppet
//! forms, and a legacy registration upgrades without changing its tokens.
use super::*;

const SERVER: &str = "example.test";
const CALLBACK: &str = "http://127.0.0.1:8088/";

fn exclusive(registration: &palpo::core::appservice::Registration, user: &str) -> bool {
    let info = palpo::appservice::RegistrationInfo::try_from(registration.clone()).unwrap();
    let user: palpo::core::OwnedUserId = user.try_into().unwrap();
    info.is_exclusive_user_match(&user)
}

fn write_legacy(path: &Path) {
    let body = json!({"id":ID,"url":CALLBACK.trim_end_matches('/'),
        "as_token":"a".repeat(64),"hs_token":"b".repeat(64),
        "sender_localpart":"_hagency_service",
        "namespaces":{"users":[{"exclusive":true,"regex":users_regex(SERVER, LEGACY_USER_LOCALPART)}],"aliases":[],"rooms":[]},
        "rate_limited":true,"receive_ephemeral":false});
    fs::write(path, serde_json::to_vec(&body).unwrap()).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
    }
}

#[test]
fn both_puppet_forms_are_reserved_so_no_person_can_register_them() {
    let dir = tempfile::tempdir().unwrap();
    let registration = load_or_create(&dir.path().join("a.json"), SERVER, CALLBACK).unwrap();
    assert!(!is_legacy(&registration, SERVER).unwrap());
    // Palpo's /register refuses any non-Appservice user this matches (M_EXCLUSIVE).
    for reserved in [
        "@_hagency_agt_01m7k5g5n36gcamvq8f8m07e6n:example.test",
        "@_hagency_csheargm_anna-claude:example.test",
        "@_hagency_csheargm_anna-claude-2:example.test",
        "@_hagency_x_y:example.test",
        "@_hagency_service:example.test",
    ] {
        assert!(exclusive(&registration, reserved), "{reserved} must be reserved");
    }
    for free in ["@alice:example.test", "@hagency_x_y:example.test", "@_hagency_x_y:other.test"] {
        assert!(!exclusive(&registration, free), "{free} is outside the namespace");
    }
}

#[test]
fn legacy_registration_upgrades_in_place_keeping_its_tokens() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("agent-appservice.json");
    write_legacy(&path);
    let legacy = load_or_create(&path, SERVER, CALLBACK).unwrap();
    assert!(is_legacy(&legacy, SERVER).unwrap());
    assert!(!exclusive(&legacy, "@_hagency_csheargm_anna-claude:example.test"), "the gap this closes");
    let upgraded = with_users_regex(&legacy, &users_regex(SERVER, USER_LOCALPART)).unwrap();
    persist_upgrade(&path, &upgraded).unwrap();
    let reloaded = load_or_create(&path, SERVER, CALLBACK).unwrap();
    assert!(!is_legacy(&reloaded, SERVER).unwrap());
    assert_eq!((reloaded.as_token.as_str(), reloaded.hs_token.as_str()), (legacy.as_token.as_str(), legacy.hs_token.as_str()));
    assert!(exclusive(&reloaded, "@_hagency_csheargm_anna-claude:example.test"));
    assert!(exclusive(&reloaded, "@_hagency_agt_01m7k5g5n36gcamvq8f8m07e6n:example.test"), "old IDs stay reserved");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(fs::metadata(&path).unwrap().permissions().mode() & 0o077, 0, "still owner-only");
    }
}

#[test]
fn a_foreign_namespace_is_never_rewritten_into_ours() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("agent-appservice.json");
    write_legacy(&path);
    let raw = fs::read_to_string(&path).unwrap().replace("_hagency_[a-z0-9_]+", "_other_[a-z0-9_]+");
    fs::write(&path, raw).unwrap();
    assert!(load_or_create(&path, SERVER, CALLBACK).is_err());
}

#[test]
fn upgrade_is_blocked_by_accounts_people_registered_in_the_widened_gap() {
    let accounts = [
        "@_hagency_service:example.test",
        "@_hagency_agt_01m7k5g5n36gcamvq8f8m07e6n:example.test",
        "@_hagency_bob_x-y:example.test",
        "@_hagency_x-y:other.test",
        "@alice:example.test",
    ];
    assert_eq!(newly_reserved(accounts.into_iter(), SERVER), vec!["@_hagency_bob_x-y:example.test".to_owned()]);
    assert!(newly_reserved(accounts[..2].iter().copied(), SERVER).is_empty());
}
