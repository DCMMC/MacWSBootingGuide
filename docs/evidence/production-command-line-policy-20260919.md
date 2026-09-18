# Production browser command-line diagnostics — 2026-09-19

## Observed configuration boundary

The read-only installed-policy receipt
`/tmp/macws-installed-policy-audit-20260919.json` records the loaded VS Code
job and its actual process arguments with:

```text
--remote-debugging-port=9222
--remote-allow-origins=*
```

The ordinary optional Chrome template likewise supplied port 9223. These are
command-line options, so the existing environment-variable and sentinel-file
inventory did not reject them. This is a configuration finding, not a measured
claim that the idle CDP endpoint caused the reported heat.

## Source contract and change

`macwshostd/main.m::SendWebURLToVSCodeExtension` connects an `AF_UNIX` stream to
`/var/mnt/rootfs/private/tmp/macws_vscode_url.sock`, sends a length-framed URL,
and checks the extension's one-byte acknowledgement. The matching
`misc/vscode-aquarium-runner/extension.js` server calls
`vscode.commands.executeCommand("simpleBrowser.show", url)`. This production
web-opening route does not use a CDP endpoint.

The two ordinary browser templates now omit the remote port and wildcard
origin options. `misc/audit_runtime_switches.py` also rejects the exact
`--remote-debugging-port`, `--remote-debugging-pipe` and
`--remote-allow-origins` options in production plists, whether spelled
`--option=value` or as separate arguments. Port zero is not treated as
disabled. Chrome's optional ordinary template is explicitly included even
though it is not automatically installed by the package; standalone
diagnostic jobs are not incorrectly classified as production.

The existing CDP/benchmark tools remain available for separately launched,
bounded diagnostic sessions. No runtime browser was restarted and no device
plist was edited for this change. The already-running VS Code therefore still
has its old arguments until a later controlled normal relaunch; source changes
alone are not evidence of live configuration convergence.

## Verification

- `PYTHONPATH=misc python3 -m unittest misc/test_production_defaults.py misc/test_runtime_gate_inventory.py`: 31 tests passed.
- Production audit: 275 discovered environment names, 77 source flag files,
  423 recorded inventory entries; passed.
- Both browser plists passed `plutil -lint`; `git diff --check` passed.
- Regression tests exercise forbidden argument spellings, malformed argv,
  exact matching without rejecting URLs/lookalike option names, both ordinary
  templates, and the source Unix-socket/web-extension contract.

These checks do not substitute for opening a real web link after the next
no-CDP browser launch. That UI acceptance remains separate from this scoped
configuration edit.

The package admission command now runs the complete source production-policy
audit before accepting an archive. A missing, failed or timed-out audit fails
admission instead of relying on a separate manual step. Package checking also
includes the actual compiler tweak and VS Code job; the latter must agree with
the current source configuration as well as the archived/staged bytes. New
tests cover these admission failures and old compiler/browser payloads.
