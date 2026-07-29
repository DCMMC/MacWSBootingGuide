"""Verify that every runtime getenv/access switch has a manifest entry.

Invoke from the repository root:
    python3 misc/audit_runtime_switches.py
"""

from __future__ import annotations

import pathlib
import plistlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "docs" / "runtime-switches.tsv"
SOURCE_SUFFIXES = {".c", ".m", ".mm", ".x", ".h", ".swift"}
EXCLUDED_PARTS = {
    ".git",
    ".theos",
    ".build",
    "packages",
    "evidence",
}


def load_manifest() -> dict[tuple[str, str], tuple[str, str, str]]:
    entries: dict[tuple[str, str], tuple[str, str, str]] = {}
    for line_number, raw in enumerate(MANIFEST.read_text().splitlines(), 1):
        if not raw or raw.startswith("#"):
            continue
        fields = raw.split("\t")
        if len(fields) != 5:
            raise ValueError(f"{MANIFEST}:{line_number}: expected 5 TSV fields")
        kind, name, production, scope, purpose = fields
        key = (kind, name)
        if key in entries:
            raise ValueError(f"{MANIFEST}:{line_number}: duplicate {kind} {name}")
        if production not in {"on", "off", "auto", "transient"}:
            raise ValueError(
                f"{MANIFEST}:{line_number}: invalid production state {production}"
            )
        entries[key] = (production, scope, purpose)
    return entries


def source_texts() -> list[str]:
    texts: list[str] = []
    for path in ROOT.rglob("*"):
        if not path.is_file() or path.suffix not in SOURCE_SUFFIXES:
            continue
        if any(part in EXCLUDED_PARTS for part in path.relative_to(ROOT).parts):
            continue
        texts.append(path.read_text(errors="ignore"))
    return texts


def plist_environment_names() -> set[str]:
    names: set[str] = set()
    candidates = list((ROOT / "layout").rglob("*.plist"))
    candidates += list((ROOT / "misc").glob("com.macwsguide.*.plist"))
    for path in candidates:
        try:
            with path.open("rb") as stream:
                value = plistlib.load(stream)
        except Exception:
            continue
        environment = value.get("EnvironmentVariables", {})
        if isinstance(environment, dict):
            names.update(str(name) for name in environment)
    return names


def main() -> int:
    manifest = load_manifest()
    texts = source_texts()
    joined = "\n".join(texts)
    env_names = set(re.findall(r'getenv\("([A-Z][A-Z0-9_]+)"\)', joined))
    env_names.update(plist_environment_names())
    flag_names = set(
        re.findall(r'access\("(/(?:private/)?tmp/macws_[^" ]+)"', joined)
    )

    missing_env = sorted(name for name in env_names if ("env", name) not in manifest)
    missing_flags = sorted(
        name for name in flag_names if ("flag", name) not in manifest
    )
    errors: list[str] = []
    if missing_env:
        errors.append("unrecorded environment switches:\n  " + "\n  ".join(missing_env))
    if missing_flags:
        errors.append("unrecorded flag files:\n  " + "\n  ".join(missing_flags))
    malloc_state = manifest.get(("env", "MallocScribble"), (None,))[0]
    if malloc_state != "off":
        errors.append("MallocScribble must be recorded as production=off")

    if errors:
        print("runtime-switch audit FAILED", file=sys.stderr)
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(
        "runtime-switch audit OK: "
        f"{len(env_names)} source/plist env names, "
        f"{len(flag_names)} source flag files, "
        f"{len(manifest)} total recorded entries"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
