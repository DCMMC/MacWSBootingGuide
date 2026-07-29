# MacWS Aquarium Runner

This disposable VS Code extension opens the WebGL Aquarium workload in the
built-in Simple Browser after the workbench starts. It exists because Electron
42 rejects browser-level `Target.createTarget`, while navigating the workbench
target directly causes VS Code to replace that renderer.

Set `macwsAquarium.url` in the disposable benchmark profile to change the fish
count or canvas dimensions. Set `macwsAquarium.openOnStartup` to `false` to
keep the command installed without opening a page automatically.

Startup is deliberately idempotent. VS Code restores Simple Browser webviews
from the disposable profile, while `simpleBrowser.show` always creates another
panel. The extension reuses one restored `WebGL Aquarium` webview and closes
only duplicate benchmark webviews before deciding whether a new one is needed.
This prevents repeated benchmark launches from accumulating independent
Chromium renderers and native-AGX resource graphs.

The dedicated `targetfix12` benchmark profile also uses
`../vscode-production-settings.json`. Copy it to
`/tmp/macws-vscode-profile-agx-native-targetfix12/User/settings.json` inside
the macOS root before loading `com.macwsguide.vscode`. It disables VS Code
1.130's optional AgentHost (Copilot/Claude background providers) and terminal
process persistence for this disposable graphics benchmark profile. Neither
setting disables the extension host, Simple Browser, WebGL2, Chromium JIT, or
native AGX.
