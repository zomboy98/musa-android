use sha2::{Digest, Sha256};
use std::path::Path;

fn main() {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../assets/bundled_extensions/soundcloud.sflx");
    println!("cargo:rerun-if-changed={}", path.display());
    let bytes = std::fs::read(path).expect("bundled SoundCloud package missing");
    let hash: String = Sha256::digest(&bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect();
    assert_eq!(
        hash, "0734a8f4868cbe5e70d5ec11edc70a50103acb107b20509978e3f51e03c68afa",
        "bundled SoundCloud package digest changed; review the in-memory compatibility override"
    );
}
