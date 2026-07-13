"""Tests for generate.py — focused on the rust-wasm client emitter (the others
are covered by each client's own test suite). Run: python3 -m unittest generate_test

Importing generate.py is side-effect free (main() is guarded), so these call the
pure emit_*/gen_* helpers directly and assert on the generated source text.
"""
import re
import unittest

import generate as g


class RustWasmEmitter(unittest.TestCase):
    def setUp(self):
        self.src = g.gen_rust_wasm()
        self.methods = [op for op in g.OPS]

    def test_every_op_becomes_one_async_method(self):
        # One `pub async fn` per operation, plus the private `request` helper.
        count = self.src.count("pub async fn ")
        self.assertEqual(count, len(g.OPS),
                         "expected one exported async method per operation")

    def test_methods_export_camelcase_js_names(self):
        # wasm-bindgen keeps snake_case by default; we pin camelCase to match the
        # TypeScript client (lockAcquire, not lock_acquire).
        for op in g.OPS:
            camel = g.camel(op["name"])
            self.assertIn("#[wasm_bindgen(js_name = %s)]" % camel, self.src,
                          "missing camelCase js_name for %s" % op["name"])

    def test_every_exported_method_has_a_js_name(self):
        # No public method may reach wasm-bindgen without an explicit js_name.
        lines = self.src.split("\n")
        for i, line in enumerate(lines):
            if line.strip().startswith("pub async fn "):
                self.assertRegex(lines[i - 1], r"#\[wasm_bindgen\(js_name = ",
                                 "unguarded method: %s" % line.strip())

    def test_ints_are_f64_not_i64(self):
        # i64 params would surface as JS `bigint`; int must map to f64 (number).
        # i64 may only appear as the `as i64` body cast, never as a param type.
        self.assertNotIn(": i64", self.src, "int param leaked as i64 (bigint)")
        self.assertNotIn(": Option<i64>", self.src)

    def test_int_bodies_serialize_as_clean_integers(self):
        # f64 int params are cast back to i64 when building the JSON body so the
        # wire form is an integer (30000, never 30000.0). lock_acquire has ttl_ms.
        self.assertIn("as i64)", self.src)

    def test_object_query_expands_to_dotted_pairs(self):
        # service_instances' `metadata` object query must expand to
        # metadata.KEY=VALUE pairs (PROTOCOL.md), not a JSON blob under `metadata`.
        fn = _method_body(self.src, "service_instances")
        self.assertIn("metadata.dyn_ref::<js_sys::Object>()", fn)
        self.assertIn('_q.push(format!("metadata.{}={}"', fn)
        self.assertNotIn('format!("metadata={}"', fn)  # no JSON-blob form
        self.assertIn('_q.join("&")', fn)

    def test_transport_uses_global_fetch_not_window(self):
        # `fetch` is resolved from the global scope so the client works on the
        # main thread, in Web Workers, and in Node/Deno — never bound to `window`.
        self.assertIn("async fn request(&self", self.src)
        self.assertIn("js_sys::global()", self.src)
        self.assertIn('js_sys::Reflect::get(&global, &JsValue::from_str("fetch")', self.src)
        self.assertNotIn("web_sys::window()", self.src)
        self.assertIn('js_sys::Reflect::set(&o, &JsValue::from_str("status")', self.src)

    def test_request_timeout_via_abort_signal(self):
        # Optional per-request timeout: constructor + setter + AbortSignal wiring.
        self.assertIn("timeout_ms: Option<f64>", self.src)
        self.assertIn("pub fn new(base_url: &str, timeout_ms: Option<f64>)", self.src)
        self.assertIn("js_name = setTimeoutMs", self.src)
        # web-sys lacks AbortSignal.timeout, so it's bound directly and used.
        self.assertIn("js_namespace = AbortSignal, js_name = timeout", self.src)
        self.assertIn("opts.set_signal(Some(&abort_signal_timeout(ms)))", self.src)

    def test_non_json_body_surfaces_raw_text(self):
        # A non-JSON response body must surface as raw text, not silently null.
        self.assertIn("unwrap_or_else(|_| JsValue::from_str(&text))", self.src)

    def test_integer_bodies_are_bounds_checked(self):
        # Integer body fields go through checked_int (fail loudly on
        # NaN/Infinity/fractional/unsafe), not a silent `as i64` cast.
        self.assertIn("fn checked_int(v: f64, field: &str) -> Result<i64, JsValue>", self.src)
        self.assertIn('checked_int(v, "ttl_ms")?', self.src)
        # The old silent `json!(<x> as i64)` body cast must be gone (the only
        # remaining `as i64` is inside checked_int's own `Ok(v as i64)`).
        self.assertNotIn("json!(v as i64)", self.src)
        self.assertNotIn('json!(ttl_ms as i64)', self.src)

    def test_metadata_values_must_be_strings(self):
        # Record<string,string> contract: non-string metadata values are rejected.
        fn = _method_body(self.src, "service_instances")
        self.assertIn("must be a string", fn)
        self.assertNotIn("unwrap_or_else", fn)  # no silent JSON.stringify coercion

    def test_default_headers_support(self):
        # Auth / idempotency-key etc. via case-insensitive default headers.
        self.assertIn("headers: Vec<(String, String)>", self.src)
        self.assertIn("js_name = setHeader", self.src)
        self.assertIn("js_name = removeHeader", self.src)
        self.assertIn("eq_ignore_ascii_case(name)", self.src)
        self.assertIn("for (name, value) in &self.headers", self.src)

    def test_no_op_leaks_a_body_for_get(self):
        # GET/DELETE without body params must pass None, never an empty payload.
        for op in g.OPS:
            body_params = [p for p in op["params"] if p["in"] == "body"]
            if not body_params:
                fn = _method_body(self.src, op["name"])
                self.assertIn("None).await", fn,
                              "%s should send no body" % op["name"])


class QueryAndPathEncoding(unittest.TestCase):
    def test_scalar_int_query_casts_to_i64(self):
        line = g._rw_scalar_enc("int", "limit")
        self.assertEqual(line, "enc(&(limit as i64).to_string())")

    def test_object_query_expands_dotted(self):
        lines = g._rw_query_lines({"name": "metadata", "type": "object", "optional": True})
        joined = "\n".join(lines)
        self.assertIn("dyn_ref::<js_sys::Object>()", joined)
        self.assertIn('format!("metadata.{}={}"', joined)
        self.assertNotIn('format!("metadata={}"', joined)

    def test_required_scalar_query_is_unconditional(self):
        lines = g._rw_query_lines({"name": "key", "type": "string"})
        self.assertEqual(len(lines), 1)
        self.assertIn('_q.push(format!("key={}"', lines[0])


class HostLanguageRegression(unittest.TestCase):
    def test_python_escapes_reserved_parameter_names(self):
        generated = g.gen_python()
        compile(generated, "generated-fiducia.py", "exec")
        self.assertIn("def handoff_offer(self, name, resource, from_, to, from_token", generated)
        self.assertIn('"from": from_', generated)

    def test_typescript_uses_node_strip_safe_constructors(self):
        generated = g.gen_ts()
        self.assertNotIn("constructor(public ", generated)
        self.assertNotIn("constructor(private ", generated)
        self.assertNotIn("query.size", generated)
        self.assertIn("this.status = status", generated)
        self.assertIn("this.base = base", generated)

    def test_optional_metadata_query_is_built_from_options(self):
        generated_go = g.gen_go()
        self.assertIn("serviceMetadataQuery(metadata)", generated_go)
        self.assertIn('values.Set("metadata."+key, metadata[key])', generated_go)
        self.assertNotIn("enc(metadata)", generated_go)
        generated_ts = g.gen_ts()
        self.assertIn("serviceMetadataQuery(metadata)", generated_ts)
        self.assertIn("`metadata.${key}`", generated_ts)
        generated_python = g.gen_python()
        self.assertIn("_metadata_query(metadata)", generated_python)
        self.assertIn('"metadata.%s"', generated_python)


class AllTargetsSmoke(unittest.TestCase):
    def test_all_generators_produce_nonempty_output(self):
        for name, (_rel, gen) in g.TARGETS.items():
            out = gen()
            self.assertTrue(out and out.strip(), "empty output for target %s" % name)


class FirstTierEmitterRegression(unittest.TestCase):
    def test_python_reserved_wire_name_is_escaped_but_preserved_in_body(self):
        src = g.gen_python()
        compile(src, "generated-fiducia.py", "exec")
        self.assertIn("def handoff_offer(self, name, resource, from_, to, from_token", src)
        self.assertIn('"from": from_', src)
        self.assertNotIn(" resource, from, to,", src)

    def test_typescript_uses_node_erasable_constructor_syntax(self):
        src = g.gen_ts()
        # Node 22's built-in strip-types parser rejects parameter properties.
        self.assertNotRegex(src, r"constructor\s*\(\s*(public|private|protected)\s+")
        self.assertIn("private base: string;", src)
        self.assertIn("constructor(baseUrl: string, opts: FiduciaClientOpts = {})", src)

    def test_go_object_query_reads_metadata_from_opts(self):
        src = g.emit_go({
            "name": "example",
            "method": "GET",
            "path": "/v1/example",
            "params": [{
                "name": "metadata",
                "in": "query",
                "type": "object",
                "optional": True,
            }],
        })
        self.assertIn('if raw, ok := opts["metadata"]', src)
        self.assertNotIn("enc(metadata)", src)
        self.assertNotIn("fmt.Sprint(metadata)", src)

    def test_every_manifest_operation_is_present_in_each_first_tier_client(self):
        python = g.gen_python()
        ts = g.gen_ts()
        go = g.gen_go()
        for op in g.OPS:
            self.assertIn("def %s(" % op["name"], python, op["name"])
            self.assertIn("%s(" % g.camel(op["name"]), ts, op["name"])
            self.assertIn(") %s(" % g.pascal(op["name"]), go, op["name"])

    def test_generation_consumes_all_template_markers(self):
        for src in (g.gen_python(), g.gen_ts(), g.gen_go()):
            self.assertNotIn("{{GENERATED_OPERATIONS}}", src)


def _method_body(src, op_name):
    """Return the source of one `pub async fn <op_name>(...) { ... }` block."""
    m = re.search(r"pub async fn %s\b" % re.escape(op_name), src)
    if not m:
        return ""
    tail = src[m.start():]
    end = tail.find("\n    }\n")
    return tail[: end if end != -1 else len(tail)]


if __name__ == "__main__":
    unittest.main()
