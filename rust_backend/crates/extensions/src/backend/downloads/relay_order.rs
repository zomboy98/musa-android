use super::Backend;
use serde_json::Value;

pub(super) const STREAMING_PRIMARY_PROVIDER: &str = "amazon";

fn id_list(priorities: &Value, key: &str) -> Result<Vec<String>, serde_json::Error> {
    let value = priorities.get(key).cloned().unwrap_or(Value::Null);
    Ok(serde_json::from_value::<Option<Vec<String>>>(value)?.unwrap_or_default())
}

pub(super) fn streaming_relay_order(
    download: Vec<String>,
    streaming: Vec<String>,
    primary: Option<&str>,
) -> Vec<String> {
    if !streaming.is_empty() {
        return streaming;
    }
    let Some(primary) = primary else {
        return download;
    };
    let mut order = download;
    let existing = order
        .iter()
        .find(|id| id.eq_ignore_ascii_case(primary))
        .cloned();
    order.retain(|id| !id.eq_ignore_ascii_case(primary));
    order.insert(0, existing.unwrap_or_else(|| primary.to_owned()));
    order
}

impl Backend {
    pub(super) fn relay_priority(
        &self,
        priorities: &Value,
        streaming: bool,
    ) -> Result<Vec<String>, serde_json::Error> {
        let download = id_list(priorities, "download")?;
        if !streaming {
            return Ok(download);
        }
        let primary = self
            .download_manifest(STREAMING_PRIMARY_PROVIDER)
            .ok()
            .filter(|manifest| manifest.has_type("download_provider"))
            .map(|manifest| manifest.name);
        Ok(streaming_relay_order(
            download,
            id_list(priorities, "streaming")?,
            primary.as_deref(),
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn ids(values: &[&str]) -> Vec<String> {
        values.iter().map(|id| (*id).to_owned()).collect()
    }

    #[test]
    fn la_lista_de_streaming_explicita_manda_sobre_la_de_descargas() {
        let order = streaming_relay_order(
            ids(&["deezer", "tidal-web"]),
            ids(&["tidal-web", "amazon"]),
            Some("amazon"),
        );
        assert_eq!(order, ids(&["tidal-web", "amazon"]));
    }

    #[test]
    fn sin_lista_de_streaming_amazon_encabeza_la_de_descargas() {
        let order = streaming_relay_order(
            ids(&["deezer", "Amazon", "tidal-web"]),
            Vec::new(),
            Some("amazon"),
        );
        assert_eq!(order, ids(&["Amazon", "deezer", "tidal-web"]));
    }

    #[test]
    fn sin_amazon_disponible_se_conserva_la_lista_de_descargas() {
        let order = streaming_relay_order(ids(&["deezer", "tidal-web"]), Vec::new(), None);
        assert_eq!(order, ids(&["deezer", "tidal-web"]));
    }

    #[test]
    fn amazon_se_anade_al_frente_si_la_lista_de_descargas_no_lo_incluye() {
        let order = streaming_relay_order(ids(&["deezer"]), Vec::new(), Some("amazon"));
        assert_eq!(order, ids(&["amazon", "deezer"]));
    }

    #[test]
    fn la_clave_ausente_o_nula_equivale_a_lista_vacia() {
        assert!(id_list(&json!({}), "streaming").unwrap().is_empty());
        assert!(id_list(&json!({"streaming": null}), "streaming").unwrap().is_empty());
        assert_eq!(
            id_list(&json!({"download": ["deezer"]}), "download").unwrap(),
            ids(&["deezer"])
        );
    }
}
