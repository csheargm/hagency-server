use super::*;
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

const SERVER: &str = "beta.test";
const PUPPET: &str = "@_hagency_agt_01k:beta.test";
const OWNER: &str = "@bird:beta.test";

/// One recorded request: method, decoded path and query, JSON body.
type Seen = Arc<Mutex<Vec<(String, String, Value)>>>;

/// A homeserver stand-in: whoami answers the puppet, a GET of the owner field
/// answers `owner_field` (404 when `None`), every write answers `{}`.
async fn homeserver(owner_field: Option<&'static str>) -> (MatrixClient, Seen) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let origin = format!("http://{}/", listener.local_addr().unwrap());
    let seen: Seen = Arc::default();
    let log = seen.clone();
    tokio::spawn(async move {
        while let Ok((mut socket, _)) = listener.accept().await {
            let request = read_request(&mut socket).await;
            let (status, body) = answer(&request, owner_field);
            log.lock().unwrap().push(request);
            let reply = format!("HTTP/1.1 {status}\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}", body.len());
            socket.write_all(reply.as_bytes()).await.unwrap();
        }
    });
    let client = MatrixClient::new(origin.parse().unwrap(), "as-token".into(), SERVER.into()).unwrap();
    (client, seen)
}

async fn read_request(socket: &mut tokio::net::TcpStream) -> (String, String, Value) {
    let mut raw = Vec::new();
    let mut buf = [0u8; 4096];
    loop {
        let n = socket.read(&mut buf).await.unwrap();
        raw.extend_from_slice(&buf[..n]);
        let text = String::from_utf8_lossy(&raw).to_string();
        let Some(end) = text.find("\r\n\r\n") else { continue };
        let length = text[..end].lines().find_map(|l| l.to_ascii_lowercase().strip_prefix("content-length: ").map(|v| v.trim().parse::<usize>().unwrap())).unwrap_or(0);
        if raw.len() < end + 4 + length { continue; }
        let mut line = text.lines().next().unwrap().split(' ');
        let (method, target) = (line.next().unwrap().to_owned(), line.next().unwrap());
        assert!(text[..end].to_ascii_lowercase().contains("authorization: bearer as-token"), "every call uses the Appservice token");
        let body = serde_json::from_slice(&raw[end + 4..end + 4 + length]).unwrap_or(Value::Null);
        return (method, urlencoding_decode(target), body);
    }
}

fn urlencoding_decode(target: &str) -> String {
    target.replace("%40", "@").replace("%3A", ":").replace("%3a", ":")
}

fn answer(request: &(String, String, Value), owner_field: Option<&str>) -> (&'static str, String) {
    let (method, path, _) = request;
    if path.contains("/account/whoami") {
        return ("200 OK", json!({"user_id": PUPPET}).to_string());
    }
    if method == "GET" && path.contains(OWNER_FIELD) {
        return match owner_field {
            Some(owner) => ("200 OK", json!({ OWNER_FIELD: owner }).to_string()),
            None => ("404 Not Found", json!({"errcode": "M_NOT_FOUND"}).to_string()),
        };
    }
    ("200 OK", "{}".into())
}

fn agent() -> Agent {
    Agent {
        visibility: crate::domain::AgentVisibility::Private, id: "agt_01k".into(), owner_user_id: "usr_bird".into(),
        puppet_mxid: PUPPET.into(), display_name: "bird-claude".into(), state: "creating".into(), generation: 1,
        owner_direct_room_id: None, execution_device_id: None,
    }
}

fn owner_puts(seen: &Seen) -> Vec<Value> {
    seen.lock().unwrap().iter().filter(|(m, p, _)| m == "PUT" && p.contains(OWNER_FIELD)).map(|(_, _, b)| b.clone()).collect()
}

/// Nov 18: an Agent's owner showed only after its desktop opened it. Now the
/// server names the owner on the profile while it creates the puppet.
#[tokio::test]
async fn provisioning_an_agent_publishes_its_owner_through_the_appservice() {
    let (client, seen) = homeserver(None).await;
    client.provision_identity(&agent(), OWNER).await.unwrap();
    let requests = seen.lock().unwrap().clone();
    let owner = requests.iter().find(|(m, p, _)| m == "PUT" && p.contains(OWNER_FIELD)).expect("owner field written");
    assert!(owner.1.starts_with(&format!("/_matrix/client/v3/profile/{PUPPET}/{OWNER_FIELD}?")), "{}", owner.1);
    assert!(owner.1.contains(&format!("user_id={PUPPET}")), "masquerades as the puppet: {}", owner.1);
    assert_eq!(owner.2, json!({ OWNER_FIELD: OWNER }));
    assert!(requests.iter().any(|(m, p, b)| m == "PUT" && p.contains("/displayname") && b["displayname"] == "bird-claude"));
    assert!(!requests.iter().any(|(_, p, _)| p.contains(RUNTIME_FIELD)), "no runtime is known at creation");
}

#[tokio::test]
async fn a_known_runtime_is_published_with_the_owner() {
    let (client, seen) = homeserver(None).await;
    client.set_agent_fields(PUPPET, OWNER, Some("claude")).await.unwrap();
    let runtime = seen.lock().unwrap().iter().find(|(_, p, _)| p.contains(RUNTIME_FIELD)).cloned().expect("runtime written");
    assert_eq!(runtime.2, json!({ RUNTIME_FIELD: "claude" }));
}

#[tokio::test]
async fn the_sweep_writes_a_missing_or_different_owner_and_skips_a_matching_one() {
    let (client, seen) = homeserver(None).await;
    client.ensure_owner_field(PUPPET, OWNER).await.unwrap();
    assert_eq!(owner_puts(&seen), vec![json!({ OWNER_FIELD: OWNER })], "missing field is written");
    let (client, seen) = homeserver(Some("@eve:beta.test")).await;
    client.ensure_owner_field(PUPPET, OWNER).await.unwrap();
    assert_eq!(owner_puts(&seen).len(), 1, "a different owner is corrected");
    let (client, seen) = homeserver(Some(OWNER)).await;
    client.ensure_owner_field(PUPPET, OWNER).await.unwrap();
    assert!(owner_puts(&seen).is_empty(), "a matching owner is not rewritten");
}

#[tokio::test]
async fn a_non_puppet_profile_is_never_written() {
    let (client, seen) = homeserver(None).await;
    assert!(client.set_agent_fields("@bird:beta.test", OWNER, None).await.is_err());
    assert!(seen.lock().unwrap().is_empty());
}
