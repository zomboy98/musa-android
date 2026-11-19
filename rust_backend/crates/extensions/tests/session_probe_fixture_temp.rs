use base64::{engine::general_purpose::STANDARD, Engine};
use mornye_extensions::{manifest::SignedSession, signed_session::protocol::{self, Record}, storage::{self, StorageMasterKey}};

#[test]
fn synthetic_probe_vector() {
    let config: SignedSession = serde_json::from_value(serde_json::json!({
        "namespace":"zarz-v2", "baseUrl":"https://api.zarz.moe/v2",
        "appVersion":"tidal-web@1.2.5", "platform":"extension",
        "schemeLabel":"ZARZ-HMAC-V1", "headerPrefix":"X-Zarz-", "timeWindowSeconds":300
    })).unwrap();
    let record: Record = serde_json::from_value(serde_json::json!({
        "install_id":"fixture-install", "session_id":"fixture-session",
        "session_secret":"fixture-secret", "expires_at":"2099-01-01T00:00:00Z"
    })).unwrap();
    let master = STANDARD.encode([7u8;32]);
    let key = StorageMasterKey::from_base64(&master).unwrap();
    let derived = key.derive("zarz-v2\nhttps://api.zarz.moe/v2\ntidal-web@1.2.5\nextension", "signed-session-v1");
    let mut encoded = b"\x89MUSA-SESSION\x01".to_vec();
    encoded.extend(storage::encrypt(&serde_json::to_vec(&record).unwrap(), &derived).unwrap());
    let body = b"{\"capability\":\"download_ticket\",\"provider\":\"tid\",\"resource_hash\":\"fixture\"}";
    let headers = protocol::signed_headers(&config, &record, "POST", "https://api.zarz.moe/v2/tickets", body, 1_800_000_000_000_000_000, "00112233445566778899aabb").unwrap();
    println!("SESSION_PROBE_SYNTHETIC={}", serde_json::json!({"master":master,"encrypted":STANDARD.encode(encoded),"headers":headers}));
}
