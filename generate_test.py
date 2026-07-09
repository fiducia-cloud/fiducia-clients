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

    def test_object_query_is_json_stringified(self):
        lines = g._rw_query_lines({"name": "metadata", "type": "object", "optional": True})
        joined = "\n".join(lines)
        self.assertIn("JSON::stringify", joined)
        self.assertTrue(joined.strip().startswith("if !metadata.is_null()"))

    def test_required_scalar_query_is_unconditional(self):
        lines = g._rw_query_lines({"name": "key", "type": "string"})
        self.assertEqual(len(lines), 1)
        self.assertIn('_q.push(format!("key={}"', lines[0])


class AllTargetsSmoke(unittest.TestCase):
    def test_all_generators_produce_nonempty_output(self):
        for name, (_rel, gen) in g.TARGETS.items():
            out = gen()
            self.assertTrue(out and out.strip(), "empty output for target %s" % name)


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
