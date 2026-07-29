const vscode = require("vscode");

async function openAquarium() {
  const configuration = vscode.workspace.getConfiguration("macwsAquarium");
  const url = configuration.get("url");
  if (typeof url !== "string" || !url.startsWith("https://")) {
    throw new Error(`macwsAquarium.url must be an HTTPS URL, got: ${url}`);
  }

  // simpleBrowser.show is the built-in extension's public command.  VS Code
  // hides it from the desktop command palette with `when: isWeb`, but command
  // execution still activates the extension and creates a normal webview
  // panel.  This keeps the workbench renderer alive instead of navigating it
  // away through CDP, which VS Code immediately detects and replaces.
  await vscode.commands.executeCommand("simpleBrowser.show", url);
}

function restoredAquariumTabs() {
  // simpleBrowser.show always creates a new webview panel.  VS Code also
  // restores the previous panels from the disposable profile, so calling it
  // unconditionally on every startup grows one full Chromium/WebGL renderer
  // per launch.  Match only this benchmark's exact page title and webview
  // input; ordinary editor and Simple Browser tabs remain untouched.
  return vscode.window.tabGroups.all
    .flatMap(group => group.tabs)
    .filter(tab => tab.label === "WebGL Aquarium");
}

async function ensureOneAquarium(createIfMissing = true) {
  const restored = restoredAquariumTabs();
  if (restored.length === 0) {
    if (createIfMissing) await openAquarium();
    return;
  }

  // Keep the already-active Aquarium when there is one; otherwise retain the
  // newest restored panel.  Close only duplicate benchmark webviews.  This is
  // an ownership fix, not a memory-pressure fallback: every duplicate is a
  // complete renderer and native-AGX resource graph created by this extension.
  const keeper = restored.find(tab => tab.isActive) ?? restored.at(-1);
  const duplicates = restored.filter(tab => tab !== keeper);
  if (duplicates.length > 0) {
    const closed = await vscode.window.tabGroups.close(duplicates, true);
    if (!closed) {
      throw new Error(`failed to close ${duplicates.length} duplicate Aquarium tabs`);
    }
  }
  console.log(
    `MACWS Aquarium reused restored tab; closed ${duplicates.length} duplicate(s)`,
  );
}

async function convergeToOneAquarium() {
  // onStartupFinished can precede VS Code's asynchronous editor restoration.
  // The first pass may legitimately see no webview and create the benchmark;
  // two later, bounded passes only prune duplicates after restored tabs have
  // entered tabGroups.  Later passes never create another panel.
  await ensureOneAquarium(true);
  await new Promise(resolve => setTimeout(resolve, 3000));
  await ensureOneAquarium(false);
  await new Promise(resolve => setTimeout(resolve, 4000));
  await ensureOneAquarium(false);
}

function activate(context) {
  context.subscriptions.push(
    vscode.commands.registerCommand("macwsAquarium.open", openAquarium),
  );

  const configuration = vscode.workspace.getConfiguration("macwsAquarium");
  if (configuration.get("openOnStartup")) {
    // onStartupFinished means the workbench is available, but the built-in
    // Simple Browser extension may still be completing activation.  Queueing
    // one short delay avoids racing its command registration without adding
    // a retry loop to the benchmark path.
    const timer = setTimeout(() => {
      convergeToOneAquarium().catch((error) => {
        console.error("MACWS Aquarium startup failed", error);
      });
    }, 1500);
    context.subscriptions.push({ dispose: () => clearTimeout(timer) });
  }
}

function deactivate() {}

module.exports = { activate, deactivate };
