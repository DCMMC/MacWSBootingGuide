// Repeatable Chrome DevTools Protocol runner for the WebGL Aquarium workload.
//
// Usage:
//   node misc/aquarium_cdp_benchmark.mjs \
//     --host 192.168.1.5 --port 9222 --fish 30000 --seconds 15

import process from "node:process";

function parseArgs(argv) {
  const args = {
    host: "127.0.0.1",
    port: 9222,
    fish: 30000,
    seconds: 15,
    width: 1024,
    height: 1024,
    warmup: 8,
    url: "https://webglsamples.org/fishtank/fishtank.html",
  };
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index]?.replace(/^--/, "");
    const value = argv[index + 1];
    if (!(key in args) || value === undefined) {
      throw new Error(`unknown or incomplete argument: ${argv[index]}`);
    }
    args[key] = ["host", "url"].includes(key) ? value : Number(value);
  }
  for (const key of ["port", "fish", "seconds", "width", "height", "warmup"]) {
    if (!Number.isFinite(args[key]) || args[key] <= 0) {
      throw new Error(`invalid --${key}: ${args[key]}`);
    }
  }
  return args;
}

async function fetchJson(url, options = {}) {
  const response = await fetch(url, options);
  if (!response.ok) {
    throw new Error(`${options.method ?? "GET"} ${url}: HTTP ${response.status}`);
  }
  return response.json();
}

class CDP {
  constructor(url) {
    this.nextId = 1;
    this.pending = new Map();
    this.events = new Map();
    this.socket = new WebSocket(url);
    this.socket.addEventListener("message", (event) => {
      const message = JSON.parse(event.data);
      if (message.id !== undefined) {
        const waiter = this.pending.get(message.id);
        if (!waiter) return;
        this.pending.delete(message.id);
        if (message.error) waiter.reject(new Error(JSON.stringify(message.error)));
        else waiter.resolve(message.result);
        return;
      }
      const waiters = this.events.get(message.method);
      if (!waiters) return;
      this.events.delete(message.method);
      for (const resolve of waiters) resolve(message.params);
    });
  }

  async open() {
    if (this.socket.readyState === WebSocket.OPEN) return;
    await new Promise((resolve, reject) => {
      this.socket.addEventListener("open", resolve, { once: true });
      this.socket.addEventListener("error", reject, { once: true });
    });
  }

  send(method, params = {}) {
    const id = this.nextId++;
    const result = new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
    });
    this.socket.send(JSON.stringify({ id, method, params }));
    return result;
  }

  waitFor(method, timeoutMs = 30000) {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`timeout waiting for ${method}`)), timeoutMs);
      const wrappedResolve = (params) => {
        clearTimeout(timer);
        resolve(params);
      };
      const waiters = this.events.get(method) ?? [];
      waiters.push(wrappedResolve);
      this.events.set(method, waiters);
    });
  }

  close() {
    this.socket.close();
  }
}

function percentile(sorted, fraction) {
  if (sorted.length === 0) return null;
  return sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * fraction))];
}

const args = parseArgs(process.argv.slice(2));
const endpoint = `http://${args.host}:${args.port}`;
let page;
try {
  page = await fetchJson(`${endpoint}/json/new?about:blank`, { method: "PUT" });
} catch (error) {
  // Electron/VS Code exposes page targets but rejects the browser-level
  // /json/new endpoint. Reuse its only page in that case; this benchmark runs
  // from a disposable VS Code profile and intentionally replaces the workbench.
  const pages = await fetchJson(`${endpoint}/json/list`);
  page = pages.find((target) => target.type === "page" && target.webSocketDebuggerUrl);
  if (!page) throw error;
}
const cdp = new CDP(page.webSocketDebuggerUrl);
await cdp.open();
await cdp.send("Page.enable");
await cdp.send("Runtime.enable");

const aquariumUrl = new URL(args.url);
aquariumUrl.searchParams.set("numFish", String(args.fish));
aquariumUrl.searchParams.set("canvasWidth", String(args.width));
aquariumUrl.searchParams.set("canvasHeight", String(args.height));
aquariumUrl.searchParams.set("fitWindow", "false");

const loaded = cdp.waitFor("Page.loadEventFired", 60000);
await cdp.send("Page.navigate", { url: aquariumUrl.href });
await loaded;

const deadline = Date.now() + 90000;
let readiness;
while (Date.now() < deadline) {
  const response = await cdp.send("Runtime.evaluate", {
    expression: `(() => {
      const canvas = document.querySelector('#canvas');
      const fps = document.querySelector('#fps')?.textContent?.trim() || '';
      if (!canvas || !fps) return {ready:false, fps};
      return {
        // Do not call getContext/getParameter here. On the cross-version AGX
        // stack those synchronous GPU IPC calls can starve CDP even while the
        // page is visibly animating. Canvas + the page's live FPS element are
        // sufficient readiness witnesses; command-error logs and VNC pixels
        // are collected independently.
        ready: true,
        fps,
        contextType: globalThis.g?.gl?.constructor?.name || null,
        canvas: [canvas.width, canvas.height],
        fishSetting: globalThis.g?.globals?.fishSetting ?? null,
        finalUrl: location.href,
        title: document.title,
      };
    })()`,
    returnByValue: true,
  });
  readiness = response.result.value;
  if (readiness?.ready) break;
  await new Promise((resolve) => setTimeout(resolve, 500));
}
if (!readiness?.ready) throw new Error(`Aquarium did not become ready: ${JSON.stringify(readiness)}`);

await new Promise((resolve) => setTimeout(resolve, args.warmup * 1000));
const benchmark = await cdp.send("Runtime.evaluate", {
  expression: `new Promise((resolve) => {
    const durationMs = ${args.seconds * 1000};
    const started = performance.now();
    const stamps = [];
    function frame(now) {
      stamps.push(now);
      if (now - started < durationMs) requestAnimationFrame(frame);
      else resolve({started, ended: now, stamps});
    }
    requestAnimationFrame(frame);
  })`,
  awaitPromise: true,
  returnByValue: true,
  timeout: (args.seconds + 30) * 1000,
});

const raw = benchmark.result.value;
const intervals = raw.stamps.slice(1).map((stamp, index) => stamp - raw.stamps[index]);
const sortedIntervals = [...intervals].sort((left, right) => left - right);
const elapsedSeconds = (raw.ended - raw.started) / 1000;
const callbackFps = raw.stamps.length / elapsedSeconds;
const instantaneousFps = intervals.map((interval) => 1000 / interval).filter(Number.isFinite);
const sortedFps = [...instantaneousFps].sort((left, right) => left - right);

const result = {
  timestamp: new Date().toISOString(),
  target: endpoint,
  url: aquariumUrl.href,
  fish: args.fish,
  requestedSeconds: args.seconds,
  elapsedSeconds,
  callbacks: raw.stamps.length,
  callbackFps,
  frameIntervalMs: {
    min: sortedIntervals[0] ?? null,
    p50: percentile(sortedIntervals, 0.50),
    p95: percentile(sortedIntervals, 0.95),
    max: sortedIntervals.at(-1) ?? null,
  },
  instantaneousFps: {
    min: sortedFps[0] ?? null,
    p50: percentile(sortedFps, 0.50),
    p95: percentile(sortedFps, 0.95),
    max: sortedFps.at(-1) ?? null,
    average: instantaneousFps.reduce((sum, value) => sum + value, 0) / instantaneousFps.length,
  },
  webgl: readiness,
};

console.log(JSON.stringify(result, null, 2));
cdp.close();
