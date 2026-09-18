//! Conformance of the committed RPC manifest against the real REST manifest.
//!
//! The unit tests in `main.rs` work on fixtures. These run against this
//! repository's actual `operations.json`, so they fail when a real operation is
//! added, renamed, or given a parameter the projection cannot place.

use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::process::Command;

fn root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .nth(2)
        .expect("repository root")
        .to_path_buf()
}

fn json(relative: &str) -> Value {
    let path = root().join(relative);
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("{}: {error}", path.display()));
    serde_json::from_str(&text).unwrap_or_else(|error| panic!("{}: {error}", path.display()))
}

/// The shared rpc_key grammar: a lowercase dotted path of at least two segments.
fn is_valid_rpc_key(key: &str) -> bool {
    let segments: Vec<&str> = key.split('.').collect();
    if segments.len() < 2 {
        return false;
    }
    segments.iter().all(|segment| {
        segment
            .chars()
            .next()
            .is_some_and(|first| first.is_ascii_lowercase())
            && segment.chars().all(|character| {
                character.is_ascii_lowercase()
                    || character.is_ascii_digit()
                    || character == '_'
                    || character == '-'
            })
    })
}

#[test]
fn the_committed_manifest_is_current_and_deterministic() {
    let output = Command::new(env!("CARGO_BIN_EXE_fiducia-rpc-manifest"))
        .arg("check")
        .arg(root())
        .output()
        .expect("generator runs");
    assert!(
        output.status.success(),
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
fn every_rest_operation_has_exactly_one_rpc_operation() {
    let rest = json("operations.json");
    let rpc = json("rpc/operations.rpc.json");

    let rest_operations = rest["operations"].as_array().expect("rest operations");
    let rpc_operations = rpc["operations"].as_array().expect("rpc operations");
    assert_eq!(
        rest_operations.len(),
        rpc_operations.len(),
        "the RPC surface must cover the REST surface exactly"
    );

    let expected: BTreeSet<String> = rest_operations
        .iter()
        .map(|operation| {
            format!(
                "fiducia.{}.{}",
                operation["group"].as_str().expect("group"),
                operation["name"].as_str().expect("name")
            )
        })
        .collect();
    let actual: BTreeSet<String> = rpc_operations
        .iter()
        .map(|operation| operation["rpc_key"].as_str().expect("rpc_key").to_owned())
        .collect();
    assert_eq!(actual, expected);
}

#[test]
fn every_key_satisfies_the_shared_grammar() {
    let rpc = json("rpc/operations.rpc.json");
    for operation in rpc["operations"].as_array().expect("operations") {
        let key = operation["rpc_key"].as_str().expect("rpc_key");
        assert!(is_valid_rpc_key(key), "{key} is not a valid rpc_key");
    }
}

#[test]
fn every_parameter_lands_in_the_section_the_rest_manifest_declares() {
    let rest = json("operations.json");
    let rpc = json("rpc/operations.rpc.json");

    let mut checked = 0_usize;
    for rest_operation in rest["operations"].as_array().expect("rest operations") {
        let key = format!(
            "fiducia.{}.{}",
            rest_operation["group"].as_str().expect("group"),
            rest_operation["name"].as_str().expect("name")
        );
        let rpc_operation = rpc["operations"]
            .as_array()
            .expect("rpc operations")
            .iter()
            .find(|candidate| candidate["rpc_key"].as_str() == Some(key.as_str()))
            .unwrap_or_else(|| panic!("{key} is absent from the RPC manifest"));

        // Where the projection actually put each parameter.
        let mut placement: BTreeMap<&str, &str> = BTreeMap::new();
        for section in ["path", "query", "body"] {
            if let Some(fields) = rpc_operation["sections"][section].as_array() {
                for field in fields {
                    let name = field["name"].as_str().expect("field name");
                    assert!(
                        placement.insert(name, section).is_none(),
                        "{key} places {name} in more than one section"
                    );
                }
            }
        }

        // Where the REST manifest says it belongs. Comparing the full mapping,
        // not just the set of names, is what catches a parameter that was
        // moved between sections rather than dropped.
        let mut declared: BTreeMap<&str, &str> = BTreeMap::new();
        if let Some(params) = rest_operation["params"].as_array() {
            for param in params {
                declared.insert(
                    param["name"].as_str().expect("param name"),
                    param["in"].as_str().expect("param location"),
                );
            }
        }

        assert_eq!(
            placement, declared,
            "{key} placed a parameter in the wrong section"
        );
        checked += declared.len();
    }
    assert!(
        checked >= 150,
        "expected the full parameter surface, checked {checked}"
    );
}

#[test]
fn the_http_projection_matches_the_rest_manifest() {
    let rest = json("operations.json");
    let rpc = json("rpc/operations.rpc.json");

    for rest_operation in rest["operations"].as_array().expect("rest operations") {
        let key = format!(
            "fiducia.{}.{}",
            rest_operation["group"].as_str().expect("group"),
            rest_operation["name"].as_str().expect("name")
        );
        let rpc_operation = rpc["operations"]
            .as_array()
            .expect("rpc operations")
            .iter()
            .find(|candidate| candidate["rpc_key"].as_str() == Some(key.as_str()))
            .expect("operation present");

        assert_eq!(
            rpc_operation["http"]["path"].as_str(),
            rest_operation["path"].as_str(),
            "{key} path drifted from the REST manifest"
        );
        assert_eq!(
            rpc_operation["http"]["method"].as_str().map(str::to_owned),
            rest_operation["method"]
                .as_str()
                .map(str::to_ascii_uppercase),
            "{key} method drifted from the REST manifest"
        );
    }
}

#[test]
fn the_operation_key_list_matches_the_manifest() {
    let rpc = json("rpc/operations.rpc.json");
    let keys = json("rpc/operation-keys.json");

    let from_manifest: Vec<&str> = rpc["operations"]
        .as_array()
        .expect("operations")
        .iter()
        .map(|operation| operation["rpc_key"].as_str().expect("rpc_key"))
        .collect();
    let from_list: Vec<&str> = keys["operation_keys"]
        .as_array()
        .expect("operation_keys")
        .iter()
        .map(|key| key.as_str().expect("key"))
        .collect();

    assert_eq!(from_list, from_manifest);
    assert_eq!(
        keys["rpc_transport_path"].as_str(),
        Some("/v1/rpc"),
        "fiducia RPC is carried on the fleet transport path"
    );
}

#[test]
fn the_surface_is_large_enough_to_be_worth_checking() {
    let rpc = json("rpc/operations.rpc.json");
    let operations = rpc["operations"].as_array().expect("operations");
    assert!(
        operations.len() >= 60,
        "expected fiducia's full operation surface, found {}",
        operations.len()
    );
    let groups: BTreeSet<&str> = operations
        .iter()
        .map(|operation| operation["group"].as_str().expect("group"))
        .collect();
    assert!(groups.len() >= 10, "expected many operation groups");
}

#[test]
fn the_manifest_declares_itself_a_projection_with_unresolved_semantics() {
    let rpc = json("rpc/operations.rpc.json");
    assert_eq!(rpc["authority"]["kind"].as_str(), Some("http_projection"));
    assert_eq!(rpc["authority"]["semantics"].as_str(), Some("unresolved"));

    // Absence of `stream` is the point: the REST manifest cannot establish it,
    // and defaulting to "unary" would turn missing evidence into a contract.
    for operation in rpc["operations"].as_array().expect("operations") {
        assert!(
            operation.get("stream").is_none(),
            "{} declares a streaming mode no authority has established",
            operation["rpc_key"]
        );
    }
}

#[test]
fn provenance_records_the_digest_of_the_real_source_manifest() {
    use std::process::Command;

    let rpc = json("rpc/operations.rpc.json");
    let recorded = rpc["provenance"]["source_manifest_sha256"]
        .as_str()
        .expect("source_manifest_sha256");
    assert_eq!(recorded.len(), 64, "expected a hex sha256");

    // Compute it independently of the generator, so a bug in one is not
    // validated by the same bug in the other.
    let output = Command::new("shasum")
        .args(["-a", "256"])
        .arg(root().join("operations.json"))
        .output()
        .expect("shasum runs");
    let actual = String::from_utf8_lossy(&output.stdout)
        .split_whitespace()
        .next()
        .expect("digest")
        .to_owned();
    assert_eq!(
        recorded, actual,
        "the recorded digest does not match operations.json on disk"
    );

    assert_eq!(
        rpc["provenance"]["source_manifest"].as_str(),
        Some("operations.json")
    );
    assert!(rpc["provenance"]["generator"].as_str().is_some());
    assert!(rpc["provenance"]["generator_version"].as_str().is_some());
}
