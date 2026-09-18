//! Derive the fiducia `/v1/rpc` operation manifest from `operations.json`.
//!
//! RPC is introduced here as a *projection* of the REST surface, not as a
//! second hand-maintained surface. Every RPC operation corresponds to exactly
//! one REST operation and carries its HTTP projection as evidence, so the two
//! cannot drift: regenerating after any change to `operations.json` is the only
//! way to change the RPC manifest, and `check` fails when the committed copy is
//! stale.
//!
//! ```text
//! fiducia-rpc-manifest generate [repo-root]   # write rpc/operations.rpc.json
//! fiducia-rpc-manifest check    [repo-root]   # determinism + staleness, no writes
//! ```
//!
//! No network, no clock, no model: output is a pure function of the input bytes.

use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

/// Transport path every fiducia RPC call is carried on, fleet-wide.
const RPC_TRANSPORT_PATH: &str = "/v1/rpc";
/// Namespace prefix for every fiducia rpc_key.
const NAMESPACE: &str = "fiducia";
const MANIFEST_VERSION: u32 = 1;

const SOURCE_MANIFEST: &str = "operations.json";
const RPC_MANIFEST: &str = "rpc/operations.rpc.json";
const OPERATION_KEYS: &str = "rpc/operation-keys.json";

#[derive(Debug, Deserialize)]
struct SourceManifest {
    version: u32,
    operations: Vec<SourceOperation>,
}

#[derive(Debug, Deserialize)]
struct SourceOperation {
    name: String,
    group: String,
    method: String,
    path: String,
    #[serde(default)]
    params: Vec<SourceParam>,
    #[serde(default)]
    doc: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
struct SourceParam {
    name: String,
    #[serde(rename = "in")]
    location: String,
    #[serde(rename = "type")]
    ty: String,
    #[serde(default)]
    required: Option<bool>,
}

#[derive(Debug, Serialize)]
struct RpcManifest {
    schema_version: u32,
    rpc_transport_path: &'static str,
    namespace: &'static str,
    source_manifest: &'static str,
    source_manifest_version: u32,
    #[serde(rename = "$comment")]
    comment: &'static str,
    operations: Vec<RpcOperation>,
}

#[derive(Debug, Serialize)]
struct RpcOperation {
    /// Canonical dotted key, the only identity an RPC caller uses.
    rpc_key: String,
    group: String,
    name: String,
    /// Unary everywhere today: fiducia has no long-lived response operations.
    /// A watch-style operation would be declared `server_stream` here and would
    /// reach the streaming client surface rather than the unary one.
    stream: &'static str,
    /// The REST shape this operation projects from. Evidence, not a second
    /// authority: it exists so a reviewer can see the two surfaces are the same
    /// operation, and so the edge can route an envelope to the existing handler.
    http: HttpProjection,
    /// Envelope sections, derived from each parameter's declared location.
    sections: Sections,
    #[serde(skip_serializing_if = "Option::is_none")]
    doc: Option<String>,
}

#[derive(Debug, Serialize)]
struct HttpProjection {
    method: String,
    path: String,
}

#[derive(Debug, Default, Serialize)]
struct Sections {
    #[serde(skip_serializing_if = "Vec::is_empty")]
    path: Vec<Field>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    query: Vec<Field>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    body: Vec<Field>,
}

#[derive(Debug, Clone, Serialize)]
struct Field {
    name: String,
    #[serde(rename = "type")]
    ty: String,
    required: bool,
}

fn main() -> ExitCode {
    let mut args = std::env::args().skip(1);
    let command = args.next().unwrap_or_else(|| "check".to_owned());
    let root = args.next().map_or_else(default_root, PathBuf::from);

    let result = match command.as_str() {
        "generate" => run_generate(&root),
        "check" => run_check(&root),
        other => Err(format!(
            "unknown command {other:?}; expected generate or check"
        )),
    };

    match result {
        Ok(report) => {
            println!("{report}");
            ExitCode::SUCCESS
        }
        Err(message) => {
            eprintln!("fiducia-rpc-manifest {command}: {message}");
            ExitCode::FAILURE
        }
    }
}

/// Walk up from the crate directory to the repository root (`rpc/generator` -> `.`).
fn default_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .nth(2)
        .map_or_else(|| PathBuf::from("."), Path::to_path_buf)
}

fn artifacts(root: &Path) -> Result<BTreeMap<String, String>, String> {
    let source = std::fs::read_to_string(root.join(SOURCE_MANIFEST))
        .map_err(|error| format!("{SOURCE_MANIFEST}: {error}"))?;
    let manifest: SourceManifest =
        serde_json::from_str(&source).map_err(|error| format!("{SOURCE_MANIFEST}: {error}"))?;

    let rpc = derive(&manifest)?;
    let keys: Vec<&str> = rpc
        .operations
        .iter()
        .map(|operation| operation.rpc_key.as_str())
        .collect();

    let mut out = BTreeMap::new();
    out.insert(RPC_MANIFEST.to_owned(), canonical_json(&rpc)?);
    out.insert(
        OPERATION_KEYS.to_owned(),
        canonical_json(&serde_json::json!({
            "$comment": "Generated from operations.json. Client SDKs import this list so an \
                         operation absent from the contract cannot be called.",
            "schema_version": MANIFEST_VERSION,
            "rpc_transport_path": RPC_TRANSPORT_PATH,
            "operation_keys": keys,
        }))?,
    );
    Ok(out)
}

/// Project the REST manifest into RPC operations.
fn derive(manifest: &SourceManifest) -> Result<RpcManifest, String> {
    let mut operations = Vec::with_capacity(manifest.operations.len());
    let mut seen: BTreeSet<String> = BTreeSet::new();

    for source in &manifest.operations {
        check_segment("group", &source.group)?;
        check_segment("name", &source.name)?;
        let rpc_key = format!("{NAMESPACE}.{}.{}", source.group, source.name);
        if !seen.insert(rpc_key.clone()) {
            return Err(format!("duplicate rpc_key {rpc_key}"));
        }

        let mut sections = Sections::default();
        for param in &source.params {
            // A parameter with no declared location cannot be placed, and
            // guessing would silently move data between sections.
            let field = Field {
                name: param.name.clone(),
                ty: param.ty.clone(),
                // The REST manifest marks optional params explicitly; anything
                // unmarked has always been required by the existing clients.
                required: param.required.unwrap_or(true),
            };
            match param.location.as_str() {
                "path" => sections.path.push(field),
                "query" => sections.query.push(field),
                "body" => sections.body.push(field),
                other => {
                    return Err(format!(
                        "{rpc_key}: parameter {:?} has unsupported location {other:?}",
                        param.name
                    ))
                }
            }
        }
        // Field order follows the REST manifest, which is the reviewed order.
        // Only the section split is derived.

        operations.push(RpcOperation {
            rpc_key,
            group: source.group.clone(),
            name: source.name.clone(),
            stream: "unary",
            http: HttpProjection {
                method: source.method.to_ascii_uppercase(),
                path: source.path.clone(),
            },
            sections,
            doc: source.doc.clone(),
        });
    }

    operations.sort_by(|left, right| left.rpc_key.cmp(&right.rpc_key));

    Ok(RpcManifest {
        schema_version: MANIFEST_VERSION,
        rpc_transport_path: RPC_TRANSPORT_PATH,
        namespace: NAMESPACE,
        source_manifest: SOURCE_MANIFEST,
        source_manifest_version: manifest.version,
        comment: "Generated by `cargo run --manifest-path rpc/generator/Cargo.toml -- generate`. \
                  Every RPC operation projects exactly one REST operation from operations.json; \
                  edit that manifest and regenerate rather than editing this file.",
        operations,
    })
}

/// rpc_key segments must satisfy the shared key grammar, which is lowercase
/// dotted with `_` and `-` admitted inside a segment.
fn check_segment(label: &str, value: &str) -> Result<(), String> {
    let valid = value
        .chars()
        .next()
        .is_some_and(|first| first.is_ascii_lowercase())
        && value.chars().all(|character| {
            character.is_ascii_lowercase()
                || character.is_ascii_digit()
                || character == '_'
                || character == '-'
        });
    if valid {
        Ok(())
    } else {
        Err(format!("{label} {value:?} is not a valid rpc_key segment"))
    }
}

fn canonical_json<T: Serialize>(value: &T) -> Result<String, String> {
    let mut buffer = Vec::with_capacity(64 * 1024);
    let formatter = serde_json::ser::PrettyFormatter::with_indent(b"  ");
    let mut serializer = serde_json::Serializer::with_formatter(&mut buffer, formatter);
    value
        .serialize(&mut serializer)
        .map_err(|error| error.to_string())?;
    let mut text = String::from_utf8(buffer).map_err(|error| error.to_string())?;
    text.push('\n');
    Ok(text)
}

fn run_generate(root: &Path) -> Result<String, String> {
    let artifacts = artifacts(root)?;
    for (relative, contents) in &artifacts {
        let path = root.join(relative);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|error| format!("{relative}: {error}"))?;
        }
        std::fs::write(&path, contents).map_err(|error| format!("{relative}: {error}"))?;
    }
    let mut report = format!("generated {} artifacts\n", artifacts.len());
    for (relative, contents) in &artifacts {
        report.push_str(&format!("  {relative} ({} bytes)\n", contents.len()));
    }
    Ok(report.trim_end().to_owned())
}

fn run_check(root: &Path) -> Result<String, String> {
    let first = artifacts(root)?;
    let second = artifacts(root)?;
    if first != second {
        return Err("derivation is not deterministic: two runs disagreed".to_owned());
    }

    let mut drifted = Vec::new();
    for (relative, expected) in &first {
        let actual = std::fs::read_to_string(root.join(relative)).unwrap_or_default();
        if &actual != expected {
            drifted.push(relative.clone());
        }
    }
    if !drifted.is_empty() {
        return Err(format!(
            "committed RPC manifest is stale; re-run `generate`:\n  {}",
            drifted.join("\n  ")
        ));
    }
    Ok(format!(
        "deterministic: {} artifacts reproduced byte-for-byte across two runs",
        first.len()
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> SourceManifest {
        serde_json::from_value(serde_json::json!({
            "version": 3,
            "operations": [
                {
                    "name": "lock_acquire",
                    "group": "locks",
                    "method": "post",
                    "path": "/v1/locks/acquire",
                    "doc": "Acquire a lock.",
                    "params": [
                        { "name": "key", "in": "body", "type": "string" },
                        { "name": "ttl_ms", "in": "body", "type": "integer", "required": false }
                    ]
                },
                {
                    "name": "lock_get",
                    "group": "locks",
                    "method": "GET",
                    "path": "/v1/locks",
                    "params": [{ "name": "key", "in": "query", "type": "string" }]
                }
            ]
        }))
        .expect("fixture parses")
    }

    #[test]
    fn keys_are_namespaced_and_sorted() {
        let rpc = derive(&fixture()).expect("derives");
        let keys: Vec<&str> = rpc.operations.iter().map(|o| o.rpc_key.as_str()).collect();
        assert_eq!(
            keys,
            ["fiducia.locks.lock_acquire", "fiducia.locks.lock_get"]
        );
    }

    #[test]
    fn every_rest_operation_projects_to_exactly_one_rpc_operation() {
        let source = fixture();
        let rpc = derive(&source).expect("derives");
        assert_eq!(rpc.operations.len(), source.operations.len());
    }

    #[test]
    fn parameters_land_in_the_section_the_rest_manifest_declares() {
        let rpc = derive(&fixture()).expect("derives");
        let acquire = &rpc.operations[0];
        assert_eq!(acquire.sections.body.len(), 2);
        assert!(acquire.sections.query.is_empty());
        assert!(acquire.sections.path.is_empty());

        let get = &rpc.operations[1];
        assert_eq!(get.sections.query.len(), 1);
        assert!(get.sections.body.is_empty());
    }

    #[test]
    fn an_unmarked_parameter_stays_required() {
        let rpc = derive(&fixture()).expect("derives");
        let body = &rpc.operations[0].sections.body;
        assert!(body[0].required, "key is unmarked and must stay required");
        assert!(!body[1].required, "ttl_ms is explicitly optional");
    }

    #[test]
    fn the_http_method_is_normalized_but_the_path_is_not() {
        let rpc = derive(&fixture()).expect("derives");
        assert_eq!(rpc.operations[0].http.method, "POST");
        assert_eq!(rpc.operations[0].http.path, "/v1/locks/acquire");
    }

    #[test]
    fn an_unsupported_parameter_location_is_refused_rather_than_guessed() {
        let mut source = fixture();
        source.operations[0].params.push(SourceParam {
            name: "x_trace".to_owned(),
            location: "header".to_owned(),
            ty: "string".to_owned(),
            required: None,
        });
        let error = derive(&source).expect_err("header is not a declared section");
        assert!(error.contains("unsupported location"), "{error}");
    }

    #[test]
    fn a_duplicate_key_is_refused() {
        let mut source = fixture();
        source.operations[1].name = "lock_acquire".to_owned();
        let error = derive(&source).expect_err("duplicate key");
        assert!(error.contains("duplicate rpc_key"), "{error}");
    }

    #[test]
    fn a_key_segment_that_breaks_the_grammar_is_refused() {
        let mut source = fixture();
        source.operations[0].group = "Locks".to_owned();
        let error = derive(&source).expect_err("uppercase segment");
        assert!(error.contains("not a valid rpc_key segment"), "{error}");
    }

    #[test]
    fn derivation_is_a_pure_function_of_its_input() {
        let first = canonical_json(&derive(&fixture()).expect("derives")).expect("serializes");
        let second = canonical_json(&derive(&fixture()).expect("derives")).expect("serializes");
        assert_eq!(first, second);
    }

    #[test]
    fn every_operation_is_unary_until_a_streaming_one_is_declared() {
        let rpc = derive(&fixture()).expect("derives");
        assert!(rpc.operations.iter().all(|o| o.stream == "unary"));
    }
}
