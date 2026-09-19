//! Derive the fiducia `/v1/rpc` operation manifest from `operations.json`.
//!
//! RPC is introduced here as a *projection* of the REST surface, not as a
//! second hand-maintained surface. Every RPC operation corresponds to exactly
//! one REST operation and carries its HTTP projection as evidence, so the two
//! cannot drift: regenerating after any change to `operations.json` is the only
//! way to change the HTTP projection, and `check` fails when the committed copy is
//! stale.
//!
//! ```text
//! fiducia-rpc-manifest generate [repo-root]   # write rpc/http-projection.json
//! fiducia-rpc-manifest check    [repo-root]   # determinism + staleness, no writes
//! ```
//!
//! No network, no clock, no model: output is a pure function of the input bytes.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

/// Transport path every fiducia RPC call is carried on, fleet-wide.
const RPC_TRANSPORT_PATH: &str = "/v1/rpc";
/// Namespace prefix for every fiducia rpc_key.
const NAMESPACE: &str = "fiducia";
const MANIFEST_VERSION: u32 = 1;

const SOURCE_MANIFEST: &str = "operations.json";
/// Named for what it is. It was `operations.rpc.json`, which reads as "the RPC
/// operations" — the semantic contract this document explicitly is not.
const RPC_MANIFEST: &str = "rpc/http-projection.json";
/// The same bytes again, filed where TJSV validates them against the authored
/// TypeSpec and JSON Schema peers of this format on every run.
const RPC_MANIFEST_INSTANCE: &str =
    "rpc/contract/instances/HttpProjectionManifest/valid/generated.json";

const OPERATION_KEYS_INSTANCE: &str =
    "rpc/contract/instances/OperationKeyList/valid/generated.json";

/// Every method an HTTP projection may name. A closed set: uppercasing whatever
/// the source says would happily emit `POTS`.
const HTTP_METHODS: &[&str] = &["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"];
const OPERATION_KEYS: &str = "rpc/operation-keys.json";

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct SourceManifest {
    #[serde(rename = "$comment", default)]
    _comment: Option<serde_json::Value>,
    version: u32,
    operations: Vec<SourceOperation>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
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

/// One REST parameter, exactly as `operations.json` spells it.
///
/// Unknown fields are refused. This struct used to read a `required` field that
/// the manifest has never had, default it to `true`, and silently ignore the
/// `optional` field the manifest actually uses — so all 63 optional parameters
/// were projected as required. serde dropped `optional` without a word because
/// nothing told it not to.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
struct SourceParam {
    name: String,
    #[serde(rename = "in")]
    location: String,
    #[serde(rename = "type")]
    ty: String,
    /// `true` marks the parameter optional; absent means required. The same
    /// rule generate.py applies (`x.get("optional")`), pinned by a conformance
    /// test against the real manifest.
    #[serde(default)]
    optional: Option<bool>,
}

#[derive(Debug, Serialize)]
struct RpcManifest {
    schema_version: u32,
    rpc_transport_path: &'static str,
    namespace: &'static str,
    /// What this document is derived from, and what it therefore is not.
    authority: Authority,
    provenance: Provenance,
    #[serde(rename = "$comment")]
    comment: &'static str,
    operations: Vec<RpcOperation>,
}

/// The authority standing behind this manifest.
///
/// Everything here is projected from the REST manifest. That makes it an HTTP
/// projection, not a semantic contract: it can say which URL an operation is
/// reachable at, and it cannot say what the operation *means*. Semantics
/// require a handlers-authoritative Contract IR, which fiducia does not have
/// yet, so they are marked unresolved rather than guessed.
#[derive(Debug, Serialize)]
struct Authority {
    kind: &'static str,
    semantics: &'static str,
    #[serde(rename = "$comment")]
    comment: &'static str,
}

/// Enough to tell which inputs produced these bytes.
#[derive(Debug, Serialize)]
struct Provenance {
    source_manifest: &'static str,
    source_manifest_version: u32,
    /// SHA-256 of the exact source manifest bytes this was derived from.
    source_manifest_sha256: String,
    generator: &'static str,
    generator_version: &'static str,
    #[serde(rename = "$comment")]
    comment: &'static str,
}

#[derive(Debug, Serialize)]
struct RpcOperation {
    /// Canonical dotted key, the only identity an RPC caller uses.
    rpc_key: String,
    group: String,
    name: String,
    /// Streaming mode, when a semantic authority has established one.
    ///
    /// Absent means *unresolved*, not unary. The REST manifest cannot tell us
    /// whether an operation streams: a single-response HTTP endpoint is how a
    /// server-streaming operation looks before it is declared one. Asserting
    /// "unary" here would turn an absence of evidence into a contract.
    #[serde(skip_serializing_if = "Option::is_none")]
    stream: Option<&'static str>,
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

    let rpc = derive(&manifest, &source)?;
    let keys: Vec<&str> = rpc
        .operations
        .iter()
        .map(|operation| operation.rpc_key.as_str())
        .collect();

    let mut out = BTreeMap::new();
    let projection = canonical_json(&rpc)?;
    out.insert(RPC_MANIFEST_INSTANCE.to_owned(), projection.clone());
    out.insert(RPC_MANIFEST.to_owned(), projection);
    let key_list = canonical_json(&serde_json::json!({
        "$comment": "Generated from operations.json. Client SDKs import this list so an \
                     operation absent from the projection cannot be called. A key list, not a contract: it says which keys exist, not what they mean.",
        "schema_version": MANIFEST_VERSION,
        "rpc_transport_path": RPC_TRANSPORT_PATH,
        "operation_keys": keys,
    }))?;
    out.insert(OPERATION_KEYS_INSTANCE.to_owned(), key_list.clone());
    out.insert(OPERATION_KEYS.to_owned(), key_list);
    Ok(out)
}

/// Project the REST manifest into RPC operations.
fn derive(manifest: &SourceManifest, source_bytes: &str) -> Result<RpcManifest, String> {
    let mut operations = Vec::with_capacity(manifest.operations.len());
    let mut seen: BTreeSet<String> = BTreeSet::new();

    for source in &manifest.operations {
        check_segment("group", &source.group)?;
        check_segment("name", &source.name)?;
        let rpc_key = format!("{NAMESPACE}.{}.{}", source.group, source.name);
        if !seen.insert(rpc_key.clone()) {
            return Err(format!("duplicate rpc_key {rpc_key}"));
        }

        let method = source.method.to_ascii_uppercase();
        if !HTTP_METHODS.contains(&method.as_str()) {
            return Err(format!(
                "{rpc_key}: {:?} is not an HTTP method ({})",
                source.method,
                HTTP_METHODS.join(", ")
            ));
        }
        let placeholders = path_placeholders(&rpc_key, &source.path)?;

        let mut sections = Sections::default();
        let mut names: BTreeSet<&str> = BTreeSet::new();
        for param in &source.params {
            // One name, one place. The same name in two sections makes the RPC
            // envelope ambiguous even though each section is well formed.
            if !names.insert(param.name.as_str()) {
                return Err(format!(
                    "{rpc_key}: parameter {:?} is declared more than once",
                    param.name
                ));
            }
            // A parameter with no declared location cannot be placed, and
            // guessing would silently move data between sections.
            let field = Field {
                name: param.name.clone(),
                ty: param.ty.clone(),
                // The REST manifest marks optional params explicitly; anything
                // unmarked has always been required by the existing clients.
                required: !param.optional.unwrap_or(false),
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

        // The path template and the path section must describe the same
        // variables, or the projection is "69 of 69" and still unroutable.
        let declared: BTreeSet<&str> = sections.path.iter().map(|f| f.name.as_str()).collect();
        let templated: BTreeSet<&str> = placeholders.iter().map(String::as_str).collect();
        if declared != templated {
            return Err(format!(
                "{rpc_key}: path {:?} has placeholders {templated:?} but the parameters \
                 declared `in: path` are {declared:?}",
                source.path
            ));
        }
        if let Some(optional) = sections.path.iter().find(|field| !field.required) {
            return Err(format!(
                "{rpc_key}: path parameter {:?} is optional, but a path segment cannot be omitted",
                optional.name
            ));
        }

        operations.push(RpcOperation {
            rpc_key,
            group: source.group.clone(),
            name: source.name.clone(),
            stream: None,
            http: HttpProjection {
                method,
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
        authority: Authority {
            kind: "http_projection",
            semantics: "unresolved",
            comment: "Derived from the REST manifest, so this document is an HTTP projection, \
                      not a semantic contract. It records which URL each operation is reachable \
                      at. It does not record what an operation means, whether it streams, or \
                      what its payload types are; those need a handlers-authoritative Contract \
                      IR, which fiducia does not have yet. Fields whose value would be a guess \
                      are omitted rather than defaulted.",
        },
        provenance: Provenance {
            source_manifest: SOURCE_MANIFEST,
            source_manifest_version: manifest.version,
            source_manifest_sha256: sha256_hex(source_bytes),
            generator: env!("CARGO_PKG_NAME"),
            generator_version: env!("CARGO_PKG_VERSION"),
            comment: "The generating commit is deliberately not embedded: it would make output \
                      depend on git state rather than on the input bytes, and the determinism \
                      gate would stop meaning anything. source_manifest_sha256 identifies the \
                      input exactly, which is the property that matters.",
        },
        comment: "Generated by `cargo run --manifest-path rpc/generator/Cargo.toml -- generate`. \
                  Every RPC operation projects exactly one REST operation from operations.json; \
                  edit that manifest and regenerate rather than editing this file.",
        operations,
    })
}

/// The `{name}` placeholders of an absolute path template, in order.
fn path_placeholders(rpc_key: &str, path: &str) -> Result<Vec<String>, String> {
    if !path.starts_with('/') {
        return Err(format!("{rpc_key}: path {path:?} is not absolute"));
    }
    let mut found = Vec::new();
    let mut rest = path;
    while let Some(open) = rest.find('{') {
        let after = &rest[open + 1..];
        let close = after
            .find('}')
            .ok_or_else(|| format!("{rpc_key}: path {path:?} has an unclosed placeholder"))?;
        let name = &after[..close];
        let well_formed = name
            .chars()
            .next()
            .is_some_and(|first| first.is_ascii_alphabetic() || first == '_')
            && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_');
        if !well_formed {
            return Err(format!(
                "{rpc_key}: path {path:?} has a malformed placeholder {{{name}}}"
            ));
        }
        if found.iter().any(|seen| seen == name) {
            return Err(format!(
                "{rpc_key}: path {path:?} repeats placeholder {{{name}}}"
            ));
        }
        found.push(name.to_owned());
        rest = &after[close + 1..];
    }
    if rest.contains('}') {
        return Err(format!(
            "{rpc_key}: path {path:?} has an unopened placeholder"
        ));
    }
    Ok(found)
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

/// Lowercase hex SHA-256 of the exact input bytes.
fn sha256_hex(source: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(source.as_bytes());
    hasher
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
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
            "committed HTTP projection is stale; re-run `generate`:\n  {}",
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

    const FIXTURE_SOURCE: &str = "{\"version\":3,\"operations\":[]}";

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
                        { "name": "ttl_ms", "in": "body", "type": "integer", "optional": true }
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
        let rpc = derive(&fixture(), FIXTURE_SOURCE).expect("derives");
        let keys: Vec<&str> = rpc.operations.iter().map(|o| o.rpc_key.as_str()).collect();
        assert_eq!(
            keys,
            ["fiducia.locks.lock_acquire", "fiducia.locks.lock_get"]
        );
    }

    #[test]
    fn every_rest_operation_projects_to_exactly_one_rpc_operation() {
        let source = fixture();
        let rpc = derive(&source, FIXTURE_SOURCE).expect("derives");
        assert_eq!(rpc.operations.len(), source.operations.len());
    }

    #[test]
    fn parameters_land_in_the_section_the_rest_manifest_declares() {
        let rpc = derive(&fixture(), FIXTURE_SOURCE).expect("derives");
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
        let rpc = derive(&fixture(), FIXTURE_SOURCE).expect("derives");
        let body = &rpc.operations[0].sections.body;
        assert!(body[0].required, "key is unmarked and must stay required");
        assert!(!body[1].required, "ttl_ms is explicitly optional");
    }

    #[test]
    fn the_http_method_is_normalized_but_the_path_is_not() {
        let rpc = derive(&fixture(), FIXTURE_SOURCE).expect("derives");
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
            optional: None,
        });
        let error = derive(&source, FIXTURE_SOURCE).expect_err("header is not a declared section");
        assert!(error.contains("unsupported location"), "{error}");
    }

    fn param(name: &str, location: &str) -> SourceParam {
        SourceParam {
            name: name.to_owned(),
            location: location.to_owned(),
            ty: "string".to_owned(),
            optional: None,
        }
    }

    /// Each case changes ONE thing in a fixture that derives cleanly, so the
    /// refusal can only be about that thing.
    #[test]
    fn a_projection_that_could_not_be_routed_is_refused() {
        derive(&fixture(), FIXTURE_SOURCE).expect("the premise: unchanged, it derives");

        type Edit = fn(&mut SourceManifest);
        let cases: [(&str, Edit, &str); 8] = [
            (
                "a typo for a method",
                |s| s.operations[0].method = "POTS".to_owned(),
                "is not an HTTP method",
            ),
            (
                "a relative path",
                |s| s.operations[0].path = "v1/locks/acquire".to_owned(),
                "is not absolute",
            ),
            (
                "a placeholder with no path parameter",
                |s| s.operations[0].path = "/v1/locks/{id}/acquire".to_owned(),
                "has placeholders",
            ),
            (
                "a path parameter with no placeholder",
                |s| s.operations[0].params.push(param("id", "path")),
                "has placeholders",
            ),
            (
                "an unclosed placeholder",
                |s| s.operations[0].path = "/v1/locks/{id".to_owned(),
                "unclosed placeholder",
            ),
            (
                "the same name in two sections",
                |s| s.operations[0].params.push(param("key", "query")),
                "declared more than once",
            ),
            (
                "the same name twice in one section",
                |s| s.operations[0].params.push(param("key", "body")),
                "declared more than once",
            ),
            (
                "an optional path segment",
                |s| {
                    s.operations[0].path = "/v1/locks/{id}".to_owned();
                    let mut id = param("id", "path");
                    id.optional = Some(true);
                    s.operations[0].params.push(id);
                },
                "cannot be omitted",
            ),
        ];
        for (why, edit, expected) in cases {
            let mut source = fixture();
            edit(&mut source);
            let error = derive(&source, FIXTURE_SOURCE).expect_err(why);
            assert!(error.contains(expected), "{why}: {error}");
        }
    }

    #[test]
    fn a_path_parameter_and_its_placeholder_agree() {
        let mut source = fixture();
        source.operations[1].path = "/v1/locks/{lock_id}".to_owned();
        source.operations[1].params.push(param("lock_id", "path"));
        let rpc = derive(&source, FIXTURE_SOURCE).expect("agreeing template and parameter");
        assert_eq!(rpc.operations[1].sections.path[0].name, "lock_id");
    }

    #[test]
    fn a_field_the_source_model_does_not_know_is_refused_not_dropped() {
        // How the `optional` bug survived: the struct read a `required` field
        // the manifest never had, and serde dropped the real one silently.
        let error = serde_json::from_value::<SourceParam>(serde_json::json!({
            "name": "ttl_ms", "in": "body", "type": "integer", "required": false
        }))
        .expect_err("an unknown spelling must not be ignored")
        .to_string();
        assert!(error.contains("unknown field `required`"), "{error}");
    }

    #[test]
    fn a_duplicate_key_is_refused() {
        let mut source = fixture();
        source.operations[1].name = "lock_acquire".to_owned();
        let error = derive(&source, FIXTURE_SOURCE).expect_err("duplicate key");
        assert!(error.contains("duplicate rpc_key"), "{error}");
    }

    #[test]
    fn a_key_segment_that_breaks_the_grammar_is_refused() {
        let mut source = fixture();
        source.operations[0].group = "Locks".to_owned();
        let error = derive(&source, FIXTURE_SOURCE).expect_err("uppercase segment");
        assert!(error.contains("not a valid rpc_key segment"), "{error}");
    }

    #[test]
    fn derivation_is_a_pure_function_of_its_input() {
        let first = canonical_json(&derive(&fixture(), FIXTURE_SOURCE).expect("derives"))
            .expect("serializes");
        let second = canonical_json(&derive(&fixture(), FIXTURE_SOURCE).expect("derives"))
            .expect("serializes");
        assert_eq!(first, second);
    }

    #[test]
    fn streaming_mode_is_left_unresolved_rather_than_assumed_unary() {
        // The REST manifest cannot establish this. Absence means unresolved.
        let rpc = derive(&fixture(), FIXTURE_SOURCE).expect("derives");
        assert!(rpc.operations.iter().all(|o| o.stream.is_none()));
        assert_eq!(rpc.authority.semantics, "unresolved");
        assert_eq!(rpc.authority.kind, "http_projection");
    }

    #[test]
    fn provenance_identifies_the_exact_input_bytes() {
        let rpc = derive(&fixture(), FIXTURE_SOURCE).expect("derives");
        assert_eq!(
            rpc.provenance.source_manifest_sha256,
            sha256_hex(FIXTURE_SOURCE)
        );
        assert_eq!(rpc.provenance.source_manifest_sha256.len(), 64);
        assert_eq!(rpc.provenance.generator, env!("CARGO_PKG_NAME"));
    }

    #[test]
    fn a_changed_source_manifest_changes_the_recorded_digest() {
        let a = derive(&fixture(), FIXTURE_SOURCE).expect("derives");
        let b = derive(&fixture(), "{\"version\":4,\"operations\":[]}").expect("derives");
        assert_ne!(
            a.provenance.source_manifest_sha256,
            b.provenance.source_manifest_sha256
        );
    }
}
