"""Inventory runtime switches and reject diagnostics in shipped launch jobs.

Invoke from the repository root:
    python3 misc/audit_runtime_switches.py
"""

from __future__ import annotations

import os
import pathlib
import plistlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "docs" / "runtime-switches.tsv"
SOURCE_SUFFIXES = {".c", ".m", ".mm", ".x", ".xm", ".h", ".swift"}
EXCLUDED_PARTS = {
    ".git",
    ".theos",
    ".build",
    "packages",
    "evidence",
    "tmp",
    "__pycache__",
}
# These are functional Steam compatibility settings explicitly set to zero in
# the shipped profile, not presence-gated diagnostics. Keep this allowlist
# exact: other production=off switches must be absent, including NAME=0.
EXPLICIT_DISABLED_ENVIRONMENT = {
    "SDL_JOYSTICK_HIDAPI": "0",
    "SDL_JOYSTICK_IOKIT": "0",
    "SDL_JOYSTICK_MFI": "0",
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
    for directory, children, files in os.walk(ROOT):
        children[:] = [name for name in children if name not in EXCLUDED_PARTS]
        for name in files:
            path = pathlib.Path(directory) / name
            if path.suffix in SOURCE_SUFFIXES:
                texts.append(path.read_text(errors="ignore"))
    return texts


def production_plists() -> list[pathlib.Path]:
    # Also cover optional jobs explicitly copied by after-stage; misc contains
    # diagnostic probes too, so treating every misc plist as shipped is wrong.
    paths = set((ROOT / "layout").rglob("*.plist"))
    for relative in re.findall(r'misc/[^\s\\]+\.plist',
                               (ROOT / "Makefile").read_text()):
        paths.add(ROOT / relative)
    return sorted(paths)


def production_environment_errors(manifest, paths) -> list[str]:
    errors = []
    for path in paths:
        try:
            with path.open("rb") as stream:
                value = plistlib.load(stream)
            environment = value.get("EnvironmentVariables", {})
            if not isinstance(environment, dict):
                raise ValueError("EnvironmentVariables must be a dictionary")
        except (OSError, ValueError, AttributeError) as error:
            errors.append(f"invalid shipped plist {path}: {error}")
            continue
        for name in environment:
            if manifest.get(("env", name), (None,))[0] == "off":
                if (name in EXPLICIT_DISABLED_ENVIRONMENT and
                        environment[name] == EXPLICIT_DISABLED_ENVIRONMENT[name]):
                    continue
                # Reject presence even with value '0': some legacy consumers
                # still test getenv(name) rather than parsing its value.
                errors.append(f"production=off environment {name} in {path}")
    return errors


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
    errors = production_environment_errors(manifest, production_plists())
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
