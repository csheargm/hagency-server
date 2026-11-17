use super::*;
use crate::{secret_token, store::Store};

const NS: &str = "_hagency_";

fn allowed(part: &str) -> bool {
    !part.is_empty()
        && part.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
        && !part.starts_with('-')
        && !part.ends_with('-')
}

#[test]
fn names_become_lowercase_ascii_slugs_with_fallbacks() {
    let slug = |s: &str| sanitize_part(s, NAME_PART_MAX, "agent");
    assert_eq!(slug("Anna Claude"), "anna-claude");
    assert_eq!(slug("  --Anna__Claude!! "), "anna-claude");
    assert_eq!(slug("Anna 安娜 2"), "anna-2");
    assert_eq!(slug("安娜"), "agent", "a non-ASCII name falls back");
    assert_eq!(slug("--- ___"), "agent");
    assert_eq!(slug("ÄNNA"), "nna", "only ASCII letters survive");
    let long = slug(&"ab ".repeat(40));
    assert!(long.len() <= NAME_PART_MAX && allowed(&long), "{long}");
    let edge = sanitize_part("abcd efgh", 5, "agent");
    assert_eq!(edge, "abcd", "a cap that lands on a separator drops it");
    for raw in ["x", "A-b", "a_b", "1 2 3", "é", "tab\there", "@:"] {
        assert!(allowed(&slug(raw)), "{raw:?} -> {:?}", slug(raw));
    }
}

#[test]
fn the_documented_example_mints_as_specified() {
    assert_eq!(base_localpart(NS, "@csheargm:localhost:8450", "Anna Claude"), "_hagency_csheargm_anna-claude");
    assert_eq!(base_localpart(NS, "@CSheargm:localhost:8450", "安娜"), "_hagency_csheargm_agent");
    assert_eq!(base_localpart(NS, "@:localhost", "Bob"), "_hagency_user_bob", "empty owner falls back");
    let worst = base_localpart(&"_".repeat(64), &format!("@{}:s", "o".repeat(99)), &"n".repeat(99));
    assert_eq!(worst.len(), 64 + OWNER_PART_MAX + 1 + NAME_PART_MAX, "both parts are capped");
}

#[test]
fn ids_are_shortened_to_fit_a_long_server_name() {
    let full = base_localpart(NS, &format!("@{}:s", "o".repeat(30)), &"n".repeat(40));
    assert_eq!(full.len(), NS.len() + OWNER_PART_MAX + 1 + NAME_PART_MAX);
    let fitted = fitted_base(NS, &format!("@{}:s", "o".repeat(30)), &"n".repeat(40), 40).unwrap();
    assert_eq!(fitted, format!("{NS}{}_{}", "o".repeat(24), "n".repeat(40 - NS.len() - 25)), "the name shrinks first");
    let tiny = fitted_base(NS, "@owner:s", "anna claude", NS.len() + 3).unwrap();
    assert_eq!(tiny, format!("{NS}o_a"), "then the owner, keeping at least one character each");
    assert_eq!(fitted_base(NS, "@owner:s", "anna", NS.len() + 2), None);
    let cut = fitted_base(NS, "@csheargm:s", "anna claude", NS.len() + 8 + 1 + 5).unwrap();
    assert_eq!(cut, format!("{NS}csheargm_anna"), "a cut never ends on a separator");
}

#[test]
fn owner_and_name_boundary_cannot_be_read_two_ways() {
    assert_ne!(base_localpart(NS, "@a_b:s", "c"), base_localpart(NS, "@a:s", "b_c"));
    assert_ne!(base_localpart(NS, "@a-b:s", "c"), base_localpart(NS, "@a:s", "b-c"));
    let owners = ["a", "a_b", "a-b", "ab", "b", "a.b", "x"];
    let names = ["c", "b_c", "b c", "b-c", "bc", "c d", "agent"];
    for (o1, n1) in owners.iter().flat_map(|o| names.iter().map(move |n| (o, n))) {
        for (o2, n2) in owners.iter().flat_map(|o| names.iter().map(move |n| (o, n))) {
            let (b1, b2) = (base_localpart(NS, &format!("@{o1}:s"), n1), base_localpart(NS, &format!("@{o2}:s"), n2));
            let parts = |o: &str, n: &str| (sanitize_part(o, OWNER_PART_MAX, "user"), sanitize_part(n, NAME_PART_MAX, "agent"));
            assert_eq!(b1 == b2, parts(o1, n1) == parts(o2, n2), "{o1}/{n1} vs {o2}/{n2}");
            let (owner, name) = b1.strip_prefix(NS).unwrap().split_once(PART_SEPARATOR).unwrap();
            assert!(allowed(owner) && allowed(name) && !name.contains(PART_SEPARATOR));
        }
    }
}

#[test]
fn collisions_take_the_next_free_numeric_suffix() {
    let base = "_hagency_csheargm_anna-claude";
    let mut taken = BTreeSet::new();
    assert_eq!(first_free(base, &taken).as_deref(), Some(base));
    taken.insert(base.to_owned());
    assert_eq!(first_free(base, &taken).unwrap(), format!("{base}-2"));
    taken.insert(format!("{base}-2"));
    taken.insert(format!("{base}-4"));
    assert_eq!(first_free(base, &taken).unwrap(), format!("{base}-3"));
    taken.extend((2..=MAX_SUFFIX).map(|n| format!("{base}-{n}")));
    assert_eq!(first_free(base, &taken), None);
}

fn create(name: &str, key: &str) -> CreateAgent {
    CreateAgent { visibility: AgentVisibility::Public, display_name: name.into(), idempotency_key: key.into() }
}

#[tokio::test]
#[ignore = "requires dedicated PostgreSQL database via HAGENCY_AGENT_TEST_DATABASE_URL"]
async fn postgres_new_agents_get_readable_unique_immutable_ids() {
    let url = std::env::var("HAGENCY_AGENT_TEST_DATABASE_URL").unwrap();
    let auth = Store::open(&url, "example.test", "https://example.test/auth/").await.unwrap();
    let domain = DomainStore::open(&url, "example.test", "_hagency_test_").await.unwrap();
    let suffix = &secret_token()[..6];
    let (_, anna) = super::super::tests::user(&auth, suffix, "anna").await;
    let (_, other) = super::super::tests::user(&auth, &format!("{suffix}x"), "anna").await;
    let now = crate::api::now_ms();
    let first = domain.create_agent(&anna, create("Anna Claude", "readable-1"), now).await.unwrap();
    let base = format!("@_hagency_test_anna-{suffix}_anna-claude");
    assert_eq!(first.puppet_mxid, format!("{base}:example.test"));
    crate::assert_entity_id(&first.id, "agt_");
    let second = domain.create_agent(&anna, create("anna  claude!", "readable-2"), now).await.unwrap();
    assert_eq!(second.puppet_mxid, format!("{base}-2:example.test"));
    let third = domain.create_agent(&anna, create("Anna Claude", "readable-3"), now).await.unwrap();
    assert_eq!(third.puppet_mxid, format!("{base}-3:example.test"));
    let replay = domain.create_agent(&anna, create("Anna Claude", "readable-1"), now).await.unwrap();
    assert_eq!((replay.id, replay.puppet_mxid), (first.id.clone(), first.puppet_mxid.clone()), "idempotent replay keeps the ID");
    let theirs = domain.create_agent(&other, create("Anna Claude", "readable-1"), now).await.unwrap();
    assert_eq!(theirs.puppet_mxid, format!("@_hagency_test_anna-{suffix}x_anna-claude:example.test"));
    let unicode = domain.create_agent(&anna, create("安娜", "readable-4"), now).await.unwrap();
    assert_eq!(unicode.puppet_mxid, format!("@_hagency_test_anna-{suffix}_agent:example.test"));
    for agent in [&first, &second, &third, &theirs, &unicode] {
        assert!(domain.known_puppet(&agent.puppet_mxid).await.unwrap());
    }
    let mut db = AsyncPgConnection::establish(&url).await.unwrap();
    let moved = sql_query("UPDATE hagency_agent_v1.agents SET puppet_mxid='@_hagency_test_moved:example.test' WHERE id=$1")
        .bind::<Text, _>(&first.id)
        .execute(&mut db)
        .await;
    assert!(moved.is_err(), "the puppet ID is immutable");
}

#[tokio::test]
#[ignore = "requires dedicated PostgreSQL database via HAGENCY_AGENT_TEST_DATABASE_URL"]
async fn postgres_concurrent_creates_with_one_name_never_share_an_id() {
    let url = std::env::var("HAGENCY_AGENT_TEST_DATABASE_URL").unwrap();
    let auth = Store::open(&url, "example.test", "https://example.test/auth/").await.unwrap();
    let suffix = &secret_token()[..6];
    let (_, p) = super::super::tests::user(&auth, suffix, "race").await;
    let p = Arc::new(p);
    let mut tasks = Vec::new();
    for n in 0..6 {
        let (url, p) = (url.clone(), Arc::clone(&p));
        tasks.push(tokio::spawn(async move {
            // Separate stores hold separate connections, as separate processes would.
            let domain = DomainStore::open(&url, "example.test", "_hagency_test_").await.unwrap();
            domain.create_agent(&p, create("Twin", &format!("race-{n}")), crate::api::now_ms()).await.unwrap().puppet_mxid
        }));
    }
    let mut minted = BTreeSet::new();
    for task in tasks {
        assert!(minted.insert(task.await.unwrap()), "duplicate puppet ID");
    }
    let base = format!("@_hagency_test_race-{suffix}_twin");
    let expected: BTreeSet<_> = std::iter::once(format!("{base}:example.test"))
        .chain((2..=6).map(|n| format!("{base}-{n}:example.test")))
        .collect();
    assert_eq!(minted, expected);
}
