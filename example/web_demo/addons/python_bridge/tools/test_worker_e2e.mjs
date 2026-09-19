/**
 * End-to-End test for the REAL addons/python_bridge/web/bridge_worker.js.
 *
 * Unlike tools/test_web_runtime.mjs (which replicates the worker's logic),
 * this harness loads the actual worker file into a Worker-shaped Node shim:
 *
 *   1. The worker URL carries the config as QUERY STRING, exactly like
 *      BridgeWebConnection._worker_url() builds it in Godot.
 *   2. The worker must self-start from the query params (no "start" message).
 *   3. The workspace tar is fetched over real HTTP from a local server.
 *   4. After {type:"ready"}, a Protocol-v2 HELLO frame must round-trip.
 *
 * Usage:
 *   node tools/test_worker_e2e.mjs --worker addons/python_bridge/web/bridge_worker.js \
 *        --bundle build/bridge_workspace.tar [--packages numpy,scipy,pandas]
 */

import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const here = dirname(fileURLToPath(import.meta.url));

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1] : fallback;
}

const workerPath = resolve(arg("worker", resolve(here, "../addons/python_bridge/web/bridge_worker.js")));
const bundlePath = resolve(arg("bundle", ""));
const packages = arg("packages", "numpy");

let passCount = 0;
let failCount = 0;
function pass(name) { passCount++; console.log(`  [PASS] ${name}`); }
function fail(name, detail) { failCount++; console.log(`  [FAIL] ${name}: ${detail}`); }
function assert(cond, name, detail = "") {
  cond ? pass(name) : fail(name, detail);
}

// ---------------------------------------------------------------- shim setup
const messages = [];
let onmessageHandler = null;
const logs = [];

globalThis.self = {
  location: { search: "" },
  postMessage: (msg) => messages.push(msg),
  onmessage: null,
  // unpackWorkspace base64-encodes the tar via self.btoa (Node has btoa).
  btoa: (s) => globalThis.btoa(s),
};
globalThis.importScripts = (_url) => {
  // The worker calls importScripts(cdn + "pyodide.js"). We serve the real
  // pyodide module from node_modules instead of the network; the package
  // resolves its own indexURL (same pyodide version).
  const pyodide = require("pyodide");
  const load = (_opts) => pyodide.loadPyodide();
  // Worker globals live on `self` in the browser shim AND on globalThis here.
  globalThis.loadPyodide = load;
  globalThis.self.loadPyodide = load;
  logs.push("shim: pyodide module injected");
};
globalThis.onmessage = null;

// ------------------------------------------------------- static file server
const mime = {
  ".tar": "application/x-tar",
  ".js": "text/javascript",
  ".json": "application/json",
};
const server = createServer(async (req, res) => {
  try {
    const name = decodeURIComponent(new URL(req.url, "http://x").pathname).replace(/^\//, "");
    const data = await readFile(resolve(dirname(bundlePath), name));
    res.writeHead(200, { "Content-Type": mime[name.slice(name.lastIndexOf("."))] || "application/octet-stream" });
    res.end(data);
  } catch {
    res.writeHead(404); res.end("not found");
  }
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const port = server.address().port;

// --------------------------------------------------------- build worker URL
const params = new URLSearchParams({
  cdn: "https://cdn.jsdelivr.net/pyodide/v0.26.4/full/",
  bundle: `http://127.0.0.1:${port}/${bundlePath.split("/").pop()}`,
  packages,
  maxStdoutBytes: "1048576",
  maxStderrBytes: "1048576",
  maxResultBytes: "268435456",
  dataRefThresholdBytes: "16777216",
  tag: "web",
});

// ------------------------------------------------------------- load worker
const workerCode = readFileSync(workerPath, "utf8");
globalThis.self.location.search = `?${params.toString()}`;
new Function(workerCode)();

// -------------------------------------------------------------- assertions
const waitFor = (pred, ms = 120000) => new Promise((resolve) => {
  const t0 = Date.now();
  const iv = setInterval(() => {
    if (pred() || Date.now() - t0 > ms) { clearInterval(iv); resolve(); }
  }, 100);
});

const startedLog = messages.find((m) => m.type === "log" && m.text.includes("config from query string"));
assert(startedLog, "worker startet selbst aus dem Query-String");

// Async startup (pyodide load + tar fetch + host init + package install).
await waitFor(() => messages.some((m) => m.type === "ready" || m.type === "error"));
assert(messages.some((m) => m.type === "log" && m.text.includes("pyodide: loaded")),
  "pyodide runtime geladen");

const ready = messages.find((m) => m.type === "ready");
const err = messages.find((m) => m.type === "error");

if (ready) {
  pass(`bridge host ready (python ${ready.status?.python ?? "?"}, platform ${ready.status?.platform ?? "?"})`);
} else if (err) {
  fail("bridge host ready", err.text);
} else {
  fail("bridge host ready", `kein ready-Event; logs=${JSON.stringify(messages.slice(0, 5))}`);
}

if (ready) {
  // Protocol-v2 HELLO -> HELLO_ACK round trip through the real dispatch path.
  const hello = JSON.stringify({ v: 2, type: "hello", id: "e2e-hello" });
  globalThis.self.onmessage({ data: { type: "bridge", text: hello } });
  const reply = messages.find((m) => m.type === "bridge" && (m.text || "").includes("hello_ack"));
  assert(reply, "hello-handshake ueber echten dispatch");

  const ping = JSON.stringify({ v: 2, type: "ping", id: "e2e-ping" });
  globalThis.self.onmessage({ data: { type: "bridge", text: ping } });
  const pong = messages.find((m) => m.type === "bridge" && (m.text || "").includes("pong"));
  assert(pong, "ping-pong ueber echten dispatch");
}

server.close();
console.log(`\n== Ergebnis: ${passCount} PASS, ${failCount} FAIL ==`);
process.exit(failCount ? 1 : 0);
