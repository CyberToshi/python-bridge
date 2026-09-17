#!/usr/bin/env node
/**
 * Real Pyodide runtime test for the Python Bridge web transport.
 *
 * Runs the ACTUAL bridge code path that the browser worker uses:
 *   1. loads Pyodide (WASM) inside Node,
 *   2. unpacks the workspace bundle tar into the virtual filesystem (MEMFS),
 *   3. installs python_bridge (browser_host.py) and packages,
 *   4. dispatches Protocol-v2 frames through js_dispatch (like bridge_worker.js),
 *   5. functionally verifies NumPy/SciPy/Pandas (real computation, not just import),
 *   6. verifies virtual FS, module/plugin loading, DataRefs, errors, cancel.
 *
 * Usage:
 *   npm install pyodide@0.26.4   (anywhere; then point PYODIDE_PKG at it)
 *   PYODIDE_PKG=/path/node_modules/pyodide node tools/test_web_runtime.mjs \
 *       [--bundle /path/bridge_workspace.tar]
 *
 * Exit code 0 = all executed checks passed; SKIPPED checks (no network for a
 * package download) are reported and documented, never claimed as working.
 */

import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const results = [];
function pass(name) { results.push(["PASS", name]); console.log("  [PASS] " + name); }
function fail(name, err) { results.push(["FAIL", name]); console.error("  [FAIL] " + name + "\n    " + (err && err.stack || err)); }
function skip(name, why) { results.push(["SKIP", name]); console.log("  [SKIP] " + name + " (" + why + ")"); }

function b64ToBytes(b64) { return Buffer.from(b64, "base64"); }

/** Parses a U32LE(header len)+JSON header binary frame (chunks ignored). */
function parseBinaryHeader(buf) {
  const hlen = buf.readUInt32LE(0);
  return JSON.parse(buf.subarray(4, 4 + hlen).toString("utf8"));
}

/** Builds a Protocol v2 binary frame with zero chunks (text-equivalent). */
function buildBinaryFrame(headerObj) {
  const head = Buffer.from(JSON.stringify(headerObj), "utf8");
  const out = Buffer.alloc(4 + head.length);
  out.writeUInt32LE(head.length, 0);
  head.copy(out, 4);
  return out;
}

/** Dispatches one frame through the JS bridge and returns raw output frames. */
function dispatch(pyodide, frame) {
  const outJson = pyodide.runPython("__bridge_host__.js_dispatch(__in_b64, __in_text)");
  return JSON.parse(outJson);
}

function dispatchText(pyodide, obj) {
  pyodide.globals.set("__in_text", JSON.stringify(obj));
  pyodide.globals.set("__in_b64", "");
  return dispatch(pyodide);
}

function dispatchBinary(pyodide, buffer) {
  pyodide.globals.set("__in_b64", buffer.toString("base64"));
  pyodide.globals.set("__in_text", "");
  return dispatch(pyodide);
}

/** Runs one run/call task and returns the parsed task_result / task_error. */
function task(pyodide, id, msg) {
  const frames = dispatchText(pyodide, { v: 2, type: "task", id, ...msg });
  if (frames.length !== 1 || !frames[0].text) throw new Error("unexpected reply frames");
  return JSON.parse(frames[0].text);
}

async function loadPackageSafe(pyodide, name) {
  try {
    await pyodide.loadPackage(name);
    return true;
  } catch (err) {
    skip("package:" + name, "download failed: " + err.message);
    return false;
  }
}

async function main() {
  const args = process.argv.slice(2);
  const bundleIdx = args.indexOf("--bundle");
  const bundlePath = bundleIdx >= 0 ? resolve(args[bundleIdx + 1]) : null;

  console.log("== Python Bridge Web-Runtime-Test (echtes Pyodide) ==");
  const pkg = process.env.PYODIDE_PKG || "pyodide";
  let pyodide;
  try {
    let pkgPath = pkg;
    if (!pkg.endsWith(".mjs") && !pkg.endsWith(".js")) {
      // Directory-Imports sind bei ES-Modulen verboten: auf die .mjs zeigen
      pkgPath = resolve(pkg, "pyodide.mjs");
    }
    const mod = await import(
      pkgPath.endsWith(".mjs") || pkgPath.endsWith(".js") ? pkgPath : pkgPath);
    pyodide = await mod.loadPyodide();
  } catch (err) {
    console.error("Pyodide konnte nicht geladen werden: " + err.message);
    process.exit(1);
  }
  pass("pyodide-runtime-startet");
  const pyVer = pyodide.runPython("import sys; sys.version.split()[0]");
  console.log("  python " + pyVer + " (wasm)");

  // --- 1) Virtual filesystem: unpack the workspace bundle -----------------
  if (bundlePath) {
    const tarBytes = new Uint8Array(readFileSync(bundlePath));
    pyodide.FS.writeFile("/tmp/bridge_workspace.tar", tarBytes);
    pyodide.runPython(`
import os, tarfile
os.makedirs("/workspace", exist_ok=True)
with tarfile.open("/tmp/bridge_workspace.tar", "r:*") as tar:
    tar.extractall("/workspace")
`);
    const hasHost = pyodide.runPython(
      "__import__('os').path.exists('/workspace/bridge/python_bridge/browser_host.py')");
    if (hasHost) pass("virtuelles-fs: workspace-bundle entpackt (browser_host.py vorhanden)");
    else { fail("virtuelles-fs", "browser_host.py fehlt nach dem Entpacken"); }
  } else {
    pyodide.runPython(`
import os
for d in ("/workspace/scripts", "/workspace/modules", "/workspace/plugins",
          "/workspace/packages", "/workspace/bridge"):
    os.makedirs(d, exist_ok=True)
`);
    skip("virtuelles-fs: bundle", "kein --bundle angegeben, leeres Workspace angelegt");
  }

  // --- 2) Install bridge package like the worker does ---------------------
  pyodide.runPython(`
import sys
sys.path.insert(0, "/workspace/bridge")
import python_bridge.browser_host as __bridge_host__
`);
  const status = JSON.parse(pyodide.runPython(
    '__bridge_host__.js_init(\'{"max_stdout_bytes": 65536}\', "/workspace", "web")'));
  if (status.platform === "web") pass("bridge-host-init");
  else fail("bridge-host-init", JSON.stringify(status));

  // --- 3) Protocol basics --------------------------------------------------
  {
    const frames = dispatchText(pyodide, { v: 2, type: "ping", id: "p1" });
    const msg = JSON.parse(frames[0].text);
    if (msg.type === "pong") pass("ping-pong"); else fail("ping-pong", JSON.stringify(msg));
  }

  {
    const frames = dispatchText(pyodide, { v: 2, type: "hello", id: "h1" });
    const msg = JSON.parse(frames[0].text);
    if (msg.type === "hello_ack" && msg.platform === "web") pass("hello-handshake");
    else fail("hello-handshake", JSON.stringify(msg));
  }

  // --- 4) run/call, parameter passing, return values -----------------------
  {
    const r = task(pyodide, "t1", { command: "run", context: "c1",
      source: "result = input['a'] + input['b']", data: { input: { a: 20, b: 22 } } });
    (r.status === "ok" && r.data === 42) ? pass("parameteruebergabe-rueckgabe")
      : fail("parameteruebergabe-rueckgabe", JSON.stringify(r));
  }
  {
    const r = task(pyodide, "t2", { command: "call", context: "c2",
      source: "def greet(name):\n    return f'Hello {name}'",
      function: "greet", data: { args: ["Godot"] } });
    (r.status === "ok" && r.data === "Hello Godot") ? pass("call-persistenter-kontext")
      : fail("call-persistenter-kontext", JSON.stringify(r));
  }

  // --- 5) Structured errors ------------------------------------------------
  {
    const r = task(pyodide, "e1", { command: "run", context: "ce",
      source: "raise ValueError('kaputt')", data: {} });
    (r.type === "task_error" && r.error.type === "ValueError" && r.error.traceback)
      ? pass("python-fehler-strukturiert") : fail("python-fehler-strukturiert", JSON.stringify(r));
  }

  // --- 6) Cooperative cancel ------------------------------------------------
  {
    dispatchText(pyodide, { v: 2, type: "cancel", id: "k0", target_id: "k1" });
    const r = task(pyodide, "k1", { command: "run", context: "ck", source: "result = 1", data: {} });
    (r.type === "task_error" && r.error.type === "CancelledError")
      ? pass("kooperative-cancellation") : fail("kooperative-cancellation", JSON.stringify(r));
  }

  // --- 7) Batch -------------------------------------------------------------
  {
    const frames = dispatchText(pyodide, { v: 2, type: "batch", id: "ba1", items: [
      { id: "i1", command: "run", context: "x1", source: "result = input * 2", data: { input: 3 } },
      { id: "i2", command: "run", context: "x2", source: "result = input * 3", data: { input: 3 } },
    ] });
    const msg = JSON.parse(frames[0].text);
    const ok = msg.type === "batch_result" && msg.items[0].data === 6 && msg.items[1].data === 9;
    ok ? pass("batch") : fail("batch", JSON.stringify(msg));
  }

  // --- 8) Introspection + reload -------------------------------------------
  {
    const frames = dispatchText(pyodide, { v: 2, type: "introspect", id: "in1",
      source: "def fn(a, b=1):\n    '''doc'''\n    return a" });
    const msg = JSON.parse(frames[0].text);
    (msg.status === "ok" && msg.functions[0].name === "fn") ? pass("introspection")
      : fail("introspection", JSON.stringify(msg));
  }
  {
    dispatchText(pyodide, { v: 2, type: "task", id: "r0", command: "run", context: "cr", source: "result = 1", data: {} });
    const frames = dispatchText(pyodide, { v: 2, type: "reload", id: "r1", context: "cr", source: "result = 2" });
    const msg = JSON.parse(frames[0].text);
    (msg.type === "reload_ack" && msg.status === "ok") ? pass("hot-reload")
      : fail("hot-reload", JSON.stringify(msg));
  }

  // --- 9) Virtual FS: write a module in MEMFS, import it in another task ----
  {
    task(pyodide, "m0", { command: "run", context: "cm", source: `
with open("/workspace/modules/calculations.py", "w") as f:
    f.write("def add(a, b):\\n    return a + b\\n")
result = True`, data: {} });
    const r = task(pyodide, "m1", { command: "call", context: "cm",
      source: "from modules.calculations import add\ndef check(v):\n    return add(v[0], v[1])",
      function: "check", data: { args: [[40, 2]] } });
    (r.status === "ok" && r.data === 42)
      ? pass("virtuelles-fs: modul schreiben + import ueber tasks hinweg")
      : fail("virtuelles-fs: modul schreiben + import ueber tasks hinweg", JSON.stringify(r));
  }
  {
    // Plugin file is importable from /workspace/plugins (bootstrap sys.path).
    task(pyodide, "pl0", { command: "run", context: "cp", source: `
with open("/workspace/plugins/example.py", "w") as f:
    f.write("def plugin_value():\\n    return 7\\n")
result = True`, data: {} });
    const r = task(pyodide, "pl1", { command: "call", context: "cp",
      source: "from plugins.example import plugin_value\ndef check():\n    return plugin_value()",
      function: "check", data: {} });
    (r.status === "ok" && r.data === 7)
      ? pass("virtuelles-fs: plugin laden") : fail("virtuelles-fs: plugin laden", JSON.stringify(r));
  }

  // --- 10) Binary frame parsing (desktop-compatible chunk framing) ----------
  {
    const frames = dispatchBinary(pyodide, buildBinaryFrame(
      { v: 2, type: "ping", id: "bin1" }));
    const msg = JSON.parse(frames[0].text);
    (msg.type === "pong" && msg.id === "bin1") ? pass("binary-frame-parse")
      : fail("binary-frame-parse", JSON.stringify(frames));
  }

  // --- 11) NumPy / SciPy / Pandas: functional verification ------------------
  const hasNumpy = await loadPackageSafe(pyodide, "numpy");
  if (hasNumpy) {
    const r = task(pyodide, "np1", { command: "call", context: "np",
      source: [
        "import numpy as np",
        "def verify():",
        "    x = np.linalg.solve(np.array([[3.0, 1.0], [1.0, 2.0]]), np.array([9.0, 8.0]))",
        "    fft_ok = bool(np.allclose(np.abs(np.fft.fft([1, 0, 0, 0])), 1.0))",
        "    a = np.arange(9, dtype=np.float64).reshape(3, 3)",
        "    mat_ok = bool(np.allclose((a @ a)[0], [15.0, 18.0, 21.0]))",
        "    return bool(np.allclose(x, [2.0, 3.0])) and fft_ok and mat_ok",
      ].join("\n"),
      function: "verify", data: {} });
    (r.status === "ok" && r.data === true)
      ? pass("numpy: solve + fft + matmul funktional")
      : fail("numpy: solve + fft + matmul funktional", JSON.stringify(r));

    // Big result -> binary frame with chunk (desktop serializer parity).
    const frames = dispatchText(pyodide, { v: 2, type: "task", id: "np2",
      command: "call", context: "np2",
      source: "import numpy as np\ndef big():\n    return np.zeros(131072, dtype=np.float64)",
      function: "big", data: {} });
    if (frames[0].b64) {
      const header = parseBinaryHeader(b64ToBytes(frames[0].b64));
      (header.type === "task_result" && header.status === "ok")
        ? pass("grosses-ergebnis-als-binary-frame") : fail("grosses-ergebnis-als-binary-frame", JSON.stringify(header));
    } else {
      fail("grosses-ergebnis-als-binary-frame", "keine binary-Antwort erhalten");
    }

    // DataRef: threshold activated by re-init; big array becomes a handle.
    pyodide.runPython(`__bridge_host__.js_init('{"data_ref_threshold_bytes": 1048576}', "/workspace", "web")`);
    const ref = task(pyodide, "dr1", { command: "call", context: "dr",
      source: "import numpy as np\ndef big():\n    return np.zeros(262144, dtype=np.int64)",
      function: "big", data: {} });
    if (ref.status === "ok" && ref.data && ref.data["$pb"] === "data_ref") {
      const got = dispatchText(pyodide, { v: 2, type: "data_get", id: "dr2",
        ref_id: ref.data.id, want: "file" });
      // Das materialisierte 2-MB-Array reist als Binaer-Frame (Chunks).
      let gm = null;
      if (got[0].b64) gm = parseBinaryHeader(b64ToBytes(got[0].b64));
      else if (got[0].text) gm = JSON.parse(got[0].text);
      if (gm && gm.status === "ok" && gm.data && gm.data["$pb"] === "ndarray"
          && gm.data.shape[0] === 262144) {
        pass("dataref-handle-und-materialisierung");
      } else {
        fail("dataref-handle-und-materialisierung", JSON.stringify(gm));
      }
    } else {
      fail("dataref-handle-und-materialisierung", JSON.stringify(ref));
    }
  } else {
    skip("numpy", "Paket nicht ladbar (siehe oben)");
  }

  const hasScipy = await loadPackageSafe(pyodide, "scipy");
  if (hasScipy) {
    const r = task(pyodide, "sp1", { command: "call", context: "sp",
      source: [
        "from scipy import integrate, optimize",
        "def verify():",
        "    val, _ = integrate.quad(lambda x: x ** 2, 0, 3)",
        "    res = optimize.minimize_scalar(lambda x: (x - 2) ** 2)",
        "    return bool(abs(val - 9.0) < 1e-6 and abs(res.x - 2.0) < 1e-3)",
      ].join("\n"),
      function: "verify", data: {} });
    (r.status === "ok" && r.data === true)
      ? pass("scipy: quad + minimize funktional")
      : fail("scipy: quad + minimize funktional", JSON.stringify(r));
  } else {
    skip("scipy", "Paket nicht ladbar (siehe oben)");
  }

  const hasPandas = await loadPackageSafe(pyodide, "pandas");
  if (hasPandas) {
    const r = task(pyodide, "pd1", { command: "call", context: "pd",
      source: [
        "import pandas as pd",
        "def verify():",
        "    df = pd.DataFrame({'k': ['a', 'a', 'b'], 'v': [1, 2, 3]})",
        "    sums = df.groupby('k')['v'].sum().to_dict()",
        "    merged = pd.DataFrame({'k': ['a', 'b'], 'w': [10, 20]})",
        "    j = df.merge(merged, on='k')",
        "    return bool(sums == {'a': 3, 'b': 3} and len(j) == 3 and int(j['w'].sum()) == 40)",
      ].join("\n"),
      function: "verify", data: {} });
    (r.status === "ok" && r.data === true)
      ? pass("pandas: groupby + merge funktional")
      : fail("pandas: groupby + merge funktional", JSON.stringify(r));
  } else {
    skip("pandas", "Paket nicht ladbar (siehe oben)");
  }

  // --- Summary --------------------------------------------------------------
  const failed = results.filter(r => r[0] === "FAIL").length;
  const skipped = results.filter(r => r[0] === "SKIP").length;
  console.log(`\n== Ergebnis: ${results.length - failed - skipped} PASS, ${failed} FAIL, ${skipped} SKIP ==`);
  if (skipped > 0) {
    console.log("Hinweis: SKIP = auf dieser Maschine nicht pruefbar (z. B. kein Netz).");
    console.log("Diese Pruefpunkte sind NICHT als bestanden zu werten - Einschränkung dokumentieren.");
  }
  process.exit(failed ? 1 : 0);
}

main().catch(err => { console.error(err); process.exit(1); });
