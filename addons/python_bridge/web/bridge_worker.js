/**
 * Python Bridge Web Worker (Pyodide).
 *
 * Runs the bridge Python package inside a Pyodide runtime with a virtual
 * filesystem. The worker is deliberately transport-dumb:
 *
 *   - Godot (main thread) posts {type:"bridge", text?|b64?} messages that
 *     mirror the desktop Protocol-v2 frames 1:1 (text JSON or the binary
 *     U32LE-header+chunks layout, base64-encoded on this boundary).
 *   - The worker forwards every frame to python_bridge.browser_host.js_dispatch
 *     and posts each outgoing frame back as {type:"bridge", text?|b64?}.
 *   - Runtime lifecycle (load Pyodide, unpack the workspace bundle, install
 *     packages) is handled here and reported via {type:"log"|"ready"|"error"}.
 *
 * Configuration comes from the query string of new Worker(url):
 *   ?pyodide=<url-or-dir>&bundle=<workspace tar.b64 url>&packages=numpy,scipy
 *   &indexURL=<explicit pyodide indexURL>
 *
 * Static hosting: everything is plain static files. `pyodideDir` enables the
 * local-bundle-first strategy (same-origin files, CDN only as fallback).
 */

let pyodide = null;
let hostReady = false;
let config = null;

function post(msg) {
  self.postMessage(msg);
}

function log(text) {
  post({ type: "log", text: String(text) });
}

function fail(text) {
  post({ type: "error", text: String(text) });
}

async function loadPyodideRuntime(cfg) {
  const dir = cfg.pyodideDir;
  if (dir) {
    // Local bundle first (same-origin, offline capable), CDN as fallback.
    try {
      importScripts(dir.replace(/\/$/, "") + "/pyodide.js");
      log("pyodide: loaded from local bundle " + dir);
      return await self.loadPyodide({ indexURL: dir.replace(/\/$/, "") + "/" });
    } catch (err) {
      log("pyodide: local bundle failed (" + err + ") - falling back to CDN");
    }
  }
  const cdn = cfg.cdnURL || "https://cdn.jsdelivr.net/pyodide/v0.26.4/full/";
  importScripts(cdn + "pyodide.js");
  log("pyodide: loaded from CDN " + cdn);
  return await self.loadPyodide({ indexURL: cdn });
}

async function unpackWorkspace(cfg) {
  const bundleURL = cfg.bundleURL;
  if (!bundleURL) {
    // No bundle: create the default workspace layout (empty).
    pyodide.runPython(`
import os
for d in ("/workspace/scripts", "/workspace/modules", "/workspace/plugins",
          "/workspace/packages", "/workspace/tmp"):
    os.makedirs(d, exist_ok=True)
`);
    return;
  }
  // Workspace bundles are tar archives, base64-encoded by the build tool.
  // Python's tarfile unpacks them into the MEMFS virtual filesystem.
  const resp = await fetch(bundleURL);
  if (!resp.ok) {
    throw new Error("workspace bundle fetch failed: " + bundleURL + " (" + resp.status + ")");
  }
  const buf = new Uint8Array(await resp.arrayBuffer());
  let binary = "";
  const chunk = 0x8000;
  for (let i = 0; i < buf.length; i += chunk) {
    binary += String.fromCharCode.apply(null, buf.subarray(i, i + chunk));
  }
  const b64 = self.btoa(binary);
  pyodide.globals.set("__bridge_bundle_b64", b64);
  pyodide.runPython(`
import base64, io, os, tarfile
data = base64.b64decode(__bridge_bundle_b64)
os.makedirs("/workspace", exist_ok=True)
with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as tar:
    tar.extractall("/workspace")
del __bridge_bundle_b64
`);
  log("workspace: unpacked bundle from " + bundleURL);
  // Ensure the default workspace layout exists. Bundles may omit empty
  // older/minimal bundles may lack directory entries - mkdir is idempotent
  // idempotent and never overwrites extracted content.
  pyodide.runPython(`
import os
for d in ("scripts", "modules", "plugins", "packages", "tmp"):
    os.makedirs("/workspace/" + d, exist_ok=True)
`);
}

async function installPackages(cfg) {
  // Called AFTER the host is initialized (see onmessage "start"): script-
  // declared dependencies (``__bridge_deps__``) are read from the workspace
  // manifest written by build_web_bundle.py and loaded through Pyodide's
  // package repository, exactly like the configured web_packages. Loading
  // before the first message guarantees user code never sees a half-ready
  // import surface.
  const packages = (cfg.packages || "").split(",").map(s => s.trim()).filter(Boolean);
  const declared = readDeclaredDeps();
  const seen = new Set();
  for (const name of packages.concat(declared)) {
    const key = String(name).toLowerCase();
    if (!key || seen.has(key)) continue;
    seen.add(key);
    log("packages: loading " + name);
    await pyodide.loadPackage(name);
  }
  if (seen.size) {
    pyodide.globals.set("__bridge_loaded_packages__", Array.from(seen));
    pyodide.runPython("__bridge_host__.js_register_packages(__bridge_loaded_packages__)");
    log("packages: loaded " + seen.size + " package(s)");
  }
}

function readDeclaredDeps() {
  // bridge_deps.json = [{"script": str, "deps": [str, ...]}, ...]
  try {
    const raw = pyodide.FS.readFile("/workspace/bridge_deps.json", { encoding: "utf8" });
    const entries = JSON.parse(raw);
    const deps = [];
    for (const e of entries || []) {
      for (const d of (e && e.deps) || []) {
        const name = String(d).split("==")[0].split(">")[0].split("<")[0].trim();
        if (name && !deps.includes(name)) deps.push(name);
      }
    }
    if (deps.length) log("packages: script dependencies " + deps.join(", "));
    return deps;
  } catch (err) {
    return [];  // no manifest: nothing script-declared (normal case)
  }
}

function num(v) {
  const n = parseInt(v, 10);
  return Number.isFinite(n) && n > 0 ? n : 0;
}

function configFromQuery() {
  // Godots Web-Transport (BridgeWebConnection._worker_url) haengt die gesamte
  // Runtime-Konfiguration als Query-Parameter an die Worker-URL - sendet aber
  // KEINE "start"-Nachricht. In einem dedizierten Worker ist self.location
  // die Skript-URL inklusive Query-String, also startet der Worker sich hier
  // selbst. Die "start"-Nachricht bleibt als alternativer Weg erhalten.
  const out = {};
  try {
    const q = new URLSearchParams(self.location.search);
    const map = {
      pyodide: "pyodideDir",
      cdn: "cdnURL",
      bundle: "bundleURL",
      packages: "packages",
      maxStdoutBytes: "maxStdoutBytes",
      maxStderrBytes: "maxStderrBytes",
      maxResultBytes: "maxResultBytes",
      dataRefThresholdBytes: "dataRefThresholdBytes",
      tag: "tag",
      autostartHello: "autostartHello",
    };
    for (const key in map) {
      const val = q.get(key);
      if (val !== null && val !== "") out[map[key]] = val;
    }
  } catch (err) {
    // Sehr alte Engines: Startup erfolgt dann per "start"-Nachricht.
  }
  return out;
}

let started = false;
function startWithConfig(cfg) {
  if (started) return;
  started = true;
  config = cfg;
  (async () => {
    try {
      pyodide = await loadPyodideRuntime(config);
      await unpackWorkspace(config);
      // Host FIRST, packages SECOND: the host must exist before any
      // message arrives, and loaded packages register themselves on it.
      // The host bootstrap is synchronous Python - no await needed.
      pyodide.runPython(`
import sys
sys.path.insert(0, "/workspace/bridge")
import python_bridge.browser_host as __bridge_host__
`);
      pyodide.globals.set("__bridge_cfg__", JSON.stringify({
        max_stdout_bytes: num(config.maxStdoutBytes),
        max_stderr_bytes: num(config.maxStderrBytes),
        max_result_bytes: num(config.maxResultBytes),
        data_ref_threshold_bytes: num(config.dataRefThresholdBytes),
      }));
      pyodide.globals.set("__bridge_tag__", String(config.tag || "web"));
      pyodide.runPython(
        '__bridge_host__.js_init(__bridge_cfg__, "/workspace", __bridge_tag__)');
      hostReady = true;
      await installPackages(config);
      const statusJson = pyodide.runPython("__bridge_host__.js_status_json()");
      const status = JSON.parse(statusJson);
      log("bridge host ready: python " + status.python + ", platform " + status.platform);
      post({ type: "ready", status: status });
      if (config.autostartHello) {
        dispatch(JSON.stringify({
          v: 2, type: "hello", id: "hello-web",
        }), "");
      }
    } catch (err) {
      fail("startup failed: " + err);
    }
  })();
}

// Self-start: die Query-Parameter sind der eigentliche Konfigurationsweg
// des Godot-Transports. Ohne Parameter bleibt alles beim "start"-Nachricht.
const __queryCfg = configFromQuery();
if (Object.keys(__queryCfg).length > 0) {
  log("worker: config from query string (" +
      Object.keys(__queryCfg).length + " params)");
  startWithConfig(__queryCfg);
}

function dispatch(text, b64) {
  // Forward one bridge frame to Python and post every outgoing frame back.
  try {
    pyodide.globals.set("__bridge_in_b64", b64 || "");
    pyodide.globals.set("__bridge_in_text", text || "");
    const outJson = pyodide.runPython(
      '__bridge_host__.js_dispatch(__bridge_in_b64, __bridge_in_text)');
    const frames = JSON.parse(outJson);
    for (const f of frames) {
      if (f.text !== undefined) {
        post({ type: "bridge", text: f.text });
      } else {
        post({ type: "bridge", b64: f.b64 });
      }
    }
  } catch (err) {
    fail("dispatch failed: " + err);
  }
}

self.onmessage = (event) => {
  const msg = event.data || {};
  if (msg.type === "bridge" && hostReady) {
    dispatch(msg.text || "", msg.b64 || "");
    return;
  }
  if (msg.type === "start") {
    // Alternativer Bootstrap (Tools/Tests): volle Konfiguration als Objekt.
    startWithConfig(msg.config || {});
  }
};
