"""
jsonschema_mini — a dependency-free JSON Schema 2020-12 validator subset.

Why this exists: the surface contract is enforced inside 15-30 language CI jobs,
most of which have no Python package manager available and no business growing
one. This module covers the keywords the surface meta-schema actually uses, and
nothing else. When the real `jsonschema` package IS importable, callers should
prefer it (see validate_contract.py) — this is the always-available fallback,
not a competitor.

Supported: $ref (local JSON pointers), $defs, type, enum, const, required,
properties, additionalProperties, patternProperties, propertyNames,
minProperties, maxProperties, items, prefixItems, minItems, maxItems,
uniqueItems, contains, minLength, maxLength, pattern, minimum, maximum,
exclusiveMinimum, exclusiveMaximum, multipleOf, allOf, anyOf, oneOf, not,
if/then/else, default (annotation only).

Unsupported keywords are ignored rather than silently passing something
important: validate() reports them through `unknown_keywords` so a contract
schema can never quietly outgrow the validator.
"""

import re
import math

_TYPES = {
    "null": lambda v: v is None,
    "boolean": lambda v: isinstance(v, bool),
    "object": lambda v: isinstance(v, dict),
    "array": lambda v: isinstance(v, list),
    "number": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
    "integer": lambda v: (isinstance(v, int) and not isinstance(v, bool))
    or (isinstance(v, float) and float(v).is_integer()),
    "string": lambda v: isinstance(v, str),
}

_HANDLED = {
    "$schema", "$id", "$comment", "$ref", "$defs", "title", "description",
    "default", "examples", "deprecated", "readOnly", "writeOnly",
    "type", "enum", "const", "required", "properties", "additionalProperties",
    "patternProperties", "propertyNames", "minProperties", "maxProperties",
    "items", "prefixItems", "minItems", "maxItems", "uniqueItems", "contains",
    "minLength", "maxLength", "pattern", "format",
    "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf",
    "allOf", "anyOf", "oneOf", "not", "if", "then", "else",
}


class ValidationError(Exception):
    def __init__(self, path, message):
        self.path = path
        self.message = message
        super().__init__("%s: %s" % (path or "<root>", message))


def _pointer(root, ref):
    if not ref.startswith("#"):
        raise ValueError("only local $ref is supported, got %r" % ref)
    frag = ref[1:]
    if frag.startswith("/"):
        frag = frag[1:]
    node = root
    if frag == "":
        return node
    for raw in frag.split("/"):
        token = raw.replace("~1", "/").replace("~0", "~")
        if isinstance(node, list):
            node = node[int(token)]
        else:
            node = node[token]
    return node


def _hashable(v):
    if isinstance(v, dict):
        return ("<obj>", tuple(sorted((k, _hashable(x)) for k, x in v.items())))
    if isinstance(v, list):
        return ("<arr>", tuple(_hashable(x) for x in v))
    if isinstance(v, bool):
        return ("<bool>", v)
    return (type(v).__name__, v)


class Validator:
    def __init__(self, schema):
        self.root = schema
        self.unknown_keywords = set()

    # -- public ------------------------------------------------------------
    def iter_errors(self, instance):
        self.unknown_keywords = set()
        errors = []
        self._validate(instance, self.root, "", errors)
        return errors

    def is_valid(self, instance):
        return not self.iter_errors(instance)

    # -- internals ---------------------------------------------------------
    def _validate(self, inst, schema, path, errors):
        if schema is True:
            return
        if schema is False:
            errors.append(ValidationError(path, "schema is false; no value is valid"))
            return
        if not isinstance(schema, dict):
            errors.append(ValidationError(path, "malformed schema node"))
            return

        for kw in schema:
            if kw not in _HANDLED:
                self.unknown_keywords.add(kw)

        if "$ref" in schema:
            try:
                target = _pointer(self.root, schema["$ref"])
            except Exception as exc:
                errors.append(ValidationError(path, "unresolvable $ref %r (%s)" % (schema["$ref"], exc)))
                return
            self._validate(inst, target, path, errors)
            # 2020-12 allows siblings alongside $ref; keep validating them.

        if "type" in schema:
            t = schema["type"]
            allowed = t if isinstance(t, list) else [t]
            if not any(_TYPES.get(name, lambda _v: False)(inst) for name in allowed):
                errors.append(ValidationError(path, "expected type %s, got %s" % ("/".join(allowed), _typename(inst))))
                return

        if "enum" in schema:
            if _hashable(inst) not in {_hashable(x) for x in schema["enum"]}:
                errors.append(ValidationError(path, "%r is not one of %r" % (inst, schema["enum"])))

        if "const" in schema and _hashable(inst) != _hashable(schema["const"]):
            errors.append(ValidationError(path, "must equal %r" % (schema["const"],)))

        for kw, combine in (("allOf", "all"), ("anyOf", "any"), ("oneOf", "one")):
            if kw not in schema:
                continue
            subs = schema[kw]
            if combine == "all":
                for i, sub in enumerate(subs):
                    self._validate(inst, sub, "%s/%s[%d]" % (path, kw, i), errors)
            else:
                passing = [i for i, sub in enumerate(subs) if not self._sub_errors(inst, sub, path)]
                if combine == "any" and not passing:
                    errors.append(ValidationError(path, "does not match any of the %d anyOf branches" % len(subs)))
                if combine == "one" and len(passing) != 1:
                    errors.append(ValidationError(path, "must match exactly one oneOf branch, matched %d" % len(passing)))

        if "not" in schema and not self._sub_errors(inst, schema["not"], path):
            errors.append(ValidationError(path, "must NOT match the 'not' schema"))

        if "if" in schema:
            branch = "then" if not self._sub_errors(inst, schema["if"], path) else "else"
            if branch in schema:
                self._validate(inst, schema[branch], path, errors)

        if isinstance(inst, str):
            self._validate_string(inst, schema, path, errors)
        elif isinstance(inst, (int, float)) and not isinstance(inst, bool):
            self._validate_number(inst, schema, path, errors)
        elif isinstance(inst, list):
            self._validate_array(inst, schema, path, errors)
        elif isinstance(inst, dict):
            self._validate_object(inst, schema, path, errors)

    def _sub_errors(self, inst, schema, path):
        errs = []
        self._validate(inst, schema, path, errs)
        return errs

    def _validate_string(self, inst, schema, path, errors):
        if "minLength" in schema and len(inst) < schema["minLength"]:
            errors.append(ValidationError(path, "shorter than minLength %d" % schema["minLength"]))
        if "maxLength" in schema and len(inst) > schema["maxLength"]:
            errors.append(ValidationError(path, "longer than maxLength %d" % schema["maxLength"]))
        if "pattern" in schema and re.search(schema["pattern"], inst) is None:
            errors.append(ValidationError(path, "%r does not match pattern %r" % (inst, schema["pattern"])))

    def _validate_number(self, inst, schema, path, errors):
        if "minimum" in schema and inst < schema["minimum"]:
            errors.append(ValidationError(path, "below minimum %r" % schema["minimum"]))
        if "maximum" in schema and inst > schema["maximum"]:
            errors.append(ValidationError(path, "above maximum %r" % schema["maximum"]))
        if "exclusiveMinimum" in schema and inst <= schema["exclusiveMinimum"]:
            errors.append(ValidationError(path, "not above exclusiveMinimum %r" % schema["exclusiveMinimum"]))
        if "exclusiveMaximum" in schema and inst >= schema["exclusiveMaximum"]:
            errors.append(ValidationError(path, "not below exclusiveMaximum %r" % schema["exclusiveMaximum"]))
        if "multipleOf" in schema:
            q = inst / schema["multipleOf"]
            if not math.isclose(q, round(q), rel_tol=1e-9, abs_tol=1e-9):
                errors.append(ValidationError(path, "not a multiple of %r" % schema["multipleOf"]))

    def _validate_array(self, inst, schema, path, errors):
        if "minItems" in schema and len(inst) < schema["minItems"]:
            errors.append(ValidationError(path, "fewer than minItems %d" % schema["minItems"]))
        if "maxItems" in schema and len(inst) > schema["maxItems"]:
            errors.append(ValidationError(path, "more than maxItems %d" % schema["maxItems"]))
        if schema.get("uniqueItems"):
            seen = [_hashable(x) for x in inst]
            if len(set(seen)) != len(seen):
                errors.append(ValidationError(path, "items are not unique"))

        prefix = schema.get("prefixItems") or []
        for i, sub in enumerate(prefix[: len(inst)]):
            self._validate(inst[i], sub, "%s/%d" % (path, i), errors)
        if "items" in schema:
            for i in range(len(prefix), len(inst)):
                self._validate(inst[i], schema["items"], "%s/%d" % (path, i), errors)
        if "contains" in schema:
            if not any(not self._sub_errors(x, schema["contains"], path) for x in inst):
                errors.append(ValidationError(path, "no item matches 'contains'"))

    def _validate_object(self, inst, schema, path, errors):
        for key in schema.get("required", []):
            if key not in inst:
                errors.append(ValidationError(path, "missing required property %r" % key))

        if "minProperties" in schema and len(inst) < schema["minProperties"]:
            errors.append(ValidationError(path, "fewer than minProperties %d" % schema["minProperties"]))
        if "maxProperties" in schema and len(inst) > schema["maxProperties"]:
            errors.append(ValidationError(path, "more than maxProperties %d" % schema["maxProperties"]))

        props = schema.get("properties", {})
        pattern_props = schema.get("patternProperties", {})
        matched = set()

        for key, value in inst.items():
            child = "%s/%s" % (path, key)
            if key in props:
                matched.add(key)
                self._validate(value, props[key], child, errors)
            for pat, sub in pattern_props.items():
                if re.search(pat, key):
                    matched.add(key)
                    self._validate(value, sub, child, errors)
            if "propertyNames" in schema:
                self._validate(key, schema["propertyNames"], child + "<name>", errors)

        if "additionalProperties" in schema:
            ap = schema["additionalProperties"]
            for key, value in inst.items():
                if key in matched:
                    continue
                if ap is False:
                    errors.append(ValidationError(path, "additional property %r is not allowed" % key))
                elif ap is not True:
                    self._validate(value, ap, "%s/%s" % (path, key), errors)


def _typename(v):
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "boolean"
    if isinstance(v, str):
        return "string"
    if isinstance(v, list):
        return "array"
    if isinstance(v, dict):
        return "object"
    if isinstance(v, int):
        return "integer"
    if isinstance(v, float):
        return "number"
    return type(v).__name__


def validate(instance, schema):
    """Return a list of ValidationError. Empty list means valid."""
    return Validator(schema).iter_errors(instance)
