use super::*;
use crate::RuntimeLimits;

#[test]
fn personal_account_failures_never_attempt_another_download_provider() {
    for (availability, enabled, mode) in [
        (
            "return {available:false,reason:'not_found'};",
            true,
            "personal",
        ),
        (
            "throw new Error('account catalog unavailable');",
            true,
            "personal",
        ),
        (
            "return {available:true,track_id:'track'};",
            true,
            "personal",
        ),
        (
            "return {available:true,track_id:'track'};",
            false,
            "personal",
        ),
        ("return {available:true,track_id:'track'};", false, "shared"),
    ] {
        let directory = tempfile::tempdir().unwrap();
        let sources = directory.path().join("sources");
        let data = directory.path().join("data");
        for id in ["example.account", "example.fallback"] {
            let source = sources.join(id);
            std::fs::create_dir_all(&source).unwrap();
            let capability = if id == "example.account" {
                json!({"accountDownloadMode":{"setting":"accountMode","value":"personal"}})
            } else {
                json!({})
            };
            std::fs::write(
                source.join("manifest.json"),
                json!({"name":id,"version":"1",
                "description":"Generic account fallback fixture","type":["download_provider"],
                "permissions":{"file":true,"storage":true},"capabilities":capability})
                .to_string(),
            )
            .unwrap();
            let behavior = if id == "example.account" {
                availability
            } else {
                "storage.set('attempts',1);return {available:true,track_id:'track'};"
            };
            std::fs::write(source.join("index.js"), format!(
                "registerExtension({{checkAvailability(){{{behavior}}},download(){{return {{success:false,error_message:'account entitlement required',error_type:'subscription_required'}};}},attempts(){{return storage.get('attempts')||0;}}}});"
            )).unwrap();
        }
        let backend = Backend::new(
            &sources,
            &data,
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            "1",
            RuntimeLimits::default(),
        )
        .unwrap();
        backend.load_all().unwrap();
        for id in ["example.account", "example.fallback"] {
            backend.set_enabled(id, true).unwrap();
        }
        backend
            .update_settings(
                "example.account",
                serde_json::from_value(json!({"accountMode":mode})).unwrap(),
            )
            .unwrap();
        backend.set_enabled("example.account", enabled).unwrap();
        backend
            .set_provider_priority(
                "download",
                vec!["example.account".into(), "example.fallback".into()],
            )
            .unwrap();
        let response = backend
            .download_by_strategy(
                &json!({"service":"example.account",
            "use_extensions":true,"use_fallback":true,"output_dir":directory.path().join("output"),
            "track_name":"Example Track","quality":"best"})
                .to_string(),
                &|| Ok(()),
            )
            .unwrap();
        let result: Value = serde_json::from_str(&response).unwrap();
        assert_eq!(result["success"], false, "{response}");
        if !enabled && mode == "personal" {
            assert_eq!(result["error_type"], "provider_unavailable", "{response}");
        }
        assert_eq!(
            backend
                .call("example.fallback", "attempts", "[]", None, 1000)
                .unwrap(),
            if mode == "personal" { "0" } else { "1" },
            "{response}"
        );
        backend.shutdown();
    }
}
