#!/bin/bash
# Backwards-compatible entry point.
# The old script required manually prepared Theos, SDKs and SSH setup.
# Use the repository-level automation instead.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT/macws-auto.sh" install "$@"
