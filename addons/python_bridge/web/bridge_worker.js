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
}

async function installPackages(cfg) {
  const packages = (cfg.packages || "").split(",").map(s => s.trim()).filter(Boolean);
  for (const name of packages) {
    log("packages: loading " + name);
    await pyodide.loadPackage(name);
  }
}

async function initHost(cfg) {
  pyodide.runPython(`
import sys
sys.path.insert(0, "/workspace/bridge")
import time
import python_bridge.browser_host as __bridge_host__
`);
  const statusJson = pyodide.runPython(
    `__bridge_host__.js_init(${JSON.stringify(JSON.stringify({
      max_stdout_bytes: num(cfg.maxStdoutBytes),
      max_stderr_bytes: num(cfg.maxStderrBytes),
      max_result_bytes: num(cfg.maxResultBytes),
      data_ref_threshold_bytes: num(cfg.dataRefThresholdBytes),
    }))}, "/workspace", ${JSON.stringify(cfg.tag || "web")})`);
  const status = JSON.parse(statusJson);
  log("bridge host ready: python " + status.python + ", platform " + status.platform);
  hostReady = true;
  post({ type: "ready", status: status });
}

function num(v) {
  const n = parseInt(v, 10);
  return Number.isFinite(n) && n > 0 ? n : 0;
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
    // Asynchronous runtime bring-up.
    (async () => {
      try {
        config = msg.config || {};
        pyodide = await loadPyodideRuntime(config);
        await unpackWorkspace(config);
        await installPackages(config);
        await initHost(config);
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
};
