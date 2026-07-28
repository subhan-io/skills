#!/usr/bin/env bash
# validate-report.sh <json-file|-> report|verdict — validate agent output against the bundled
# schema before posting it to GitHub. Exit 0 valid, 2 invalid (violations on stderr).
# Uses python3 jsonschema if installed; otherwise a built-in checker covering everything these
# two schemas actually use (required, type, enum, array items, the schemaTouched→scratchDb rule).
set -euo pipefail
source "$(dirname "$0")/common.sh"
need python3

FILE="${1:-}"; KIND="${2:-}"
[ -n "$FILE" ] && { [ "$KIND" = "report" ] || [ "$KIND" = "verdict" ]; } \
  || die "usage: validate-report.sh <json-file|-> report|verdict"
SCHEMA="$SKILL_DIR/${KIND}-schema.json"
[ -f "$SCHEMA" ] || die "schema not found: $SCHEMA"

if [ "$FILE" = "-" ]; then DATA="$(cat)"; else DATA="$(cat "$FILE")"; fi
export DATA SCHEMA

python3 - <<'PY'
import json, os, sys

data = json.loads(os.environ["DATA"])
schema = json.load(open(os.environ["SCHEMA"]))

try:
    import jsonschema
    try:
        jsonschema.validate(data, schema)
        print("valid")
        sys.exit(0)
    except jsonschema.ValidationError as e:
        print(f"INVALID: {e.message} (at {'/'.join(map(str, e.absolute_path)) or 'root'})", file=sys.stderr)
        sys.exit(2)
except ImportError:
    pass

# Minimal fallback validator for the subset these schemas use.
errors = []
TYPES = {"object": dict, "array": list, "string": str, "integer": int, "boolean": bool, "null": type(None)}

def check(value, sch, path):
    t = sch.get("type")
    if t is not None:
        allowed = t if isinstance(t, list) else [t]
        pytypes = tuple(TYPES[a] for a in allowed)
        ok = isinstance(value, pytypes)
        if isinstance(value, bool) and "boolean" not in allowed:
            ok = False  # bool is a subclass of int
        if not ok:
            errors.append(f"{path or 'root'}: expected {allowed}, got {type(value).__name__}")
            return
    if "enum" in sch and value not in sch["enum"]:
        errors.append(f"{path or 'root'}: {value!r} not in {sch['enum']}")
    if isinstance(value, dict):
        for req in sch.get("required", []):
            if req not in value:
                errors.append(f"{path or 'root'}: missing required key {req!r}")
        for k, sub in sch.get("properties", {}).items():
            if k in value:
                check(value[k], sub, f"{path}/{k}")
    if isinstance(value, list) and "items" in sch:
        for i, item in enumerate(value):
            check(item, sch["items"], f"{path}[{i}]")

check(data, schema, "")
# if/then (report schema: schemaTouched=true requires scratchDb)
if "if" in schema and "then" in schema and isinstance(data, dict):
    cond = all(data.get(k) == v.get("const") for k, v in schema["if"].get("properties", {}).items())
    if cond:
        for req in schema["then"].get("required", []):
            if req not in data:
                errors.append(f"root: missing {req!r} (required when condition holds)")

if errors:
    print("INVALID:", file=sys.stderr)
    for e in errors:
        print(f"  - {e}", file=sys.stderr)
    sys.exit(2)
print("valid")
PY
