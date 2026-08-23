#!/usr/bin/env python3
"""Validate an agent report against the JSON Schema subset bundled with ship-issue."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


def fail(message: str) -> None:
    print(f"INVALID: {message}", file=sys.stderr)
    raise SystemExit(65)


def fallback_validate(value: Any, schema: dict[str, Any], path: str = "root") -> list[str]:
    errors: list[str] = []
    declared_type = schema.get("type")
    if declared_type is not None:
        allowed = declared_type if isinstance(declared_type, list) else [declared_type]
        type_map = {
            "object": dict,
            "array": list,
            "string": str,
            "integer": int,
            "number": (int, float),
            "boolean": bool,
            "null": type(None),
        }
        expected = tuple(type_map[item] for item in allowed)
        valid_type = isinstance(value, expected)
        if isinstance(value, bool) and "boolean" not in allowed:
            valid_type = False
        if not valid_type:
            return [f"{path}: expected {allowed}, got {type(value).__name__}"]

    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{path}: {value!r} is not one of {schema['enum']!r}")

    if isinstance(value, str):
        if len(value) < schema.get("minLength", 0):
            errors.append(f"{path}: string is shorter than minLength")
        if schema.get("format") == "uri" and not value.startswith(("http://", "https://")):
            errors.append(f"{path}: expected an HTTP(S) URI")

    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            errors.append(f"{path}: value is below minimum {schema['minimum']}")

    if isinstance(value, dict):
        for required in schema.get("required", []):
            if required not in value:
                errors.append(f"{path}: missing required key {required!r}")
        properties = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            for key in value.keys() - properties.keys():
                errors.append(f"{path}: unexpected key {key!r}")
        for key, child_schema in properties.items():
            if key in value:
                errors.extend(fallback_validate(value[key], child_schema, f"{path}/{key}"))

    if isinstance(value, list):
        if len(value) < schema.get("minItems", 0):
            errors.append(f"{path}: array has fewer than {schema['minItems']} items")
        if "items" in schema:
            for index, item in enumerate(value):
                errors.extend(fallback_validate(item, schema["items"], f"{path}[{index}]"))

    return errors


def main() -> None:
    if len(sys.argv) != 3:
        print("usage: validate-agent-report.py <schema.json> <report.json>", file=sys.stderr)
        raise SystemExit(64)

    schema_path, report_path = map(Path, sys.argv[1:])
    try:
        schema = json.loads(schema_path.read_text())
        report = json.loads(report_path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        fail(str(exc))

    try:
        import jsonschema
    except ImportError:
        errors = fallback_validate(report, schema)
        if errors:
            fail("; ".join(errors))
    else:
        try:
            jsonschema.validate(report, schema)
        except jsonschema.ValidationError as exc:
            location = "/".join(map(str, exc.absolute_path)) or "root"
            fail(f"{exc.message} (at {location})")

    print("valid")


if __name__ == "__main__":
    main()
