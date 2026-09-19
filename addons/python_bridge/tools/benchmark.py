#!/usr/bin/env python3
"""Benchmark-Harness der Python Bridge (Phase 0 - Messbarkeit).

Misst reproduzierbar die Kosten, die die Bottleneck-Analyse nennt:

  - JSON-Header vs Binary-Chunk-Transport (D1): Wie viel Bytes kostet eine
    numerische Liste als JSON-Zahlenliste gegenueber rohen LE-Bytes?
  - Serialisierung (A7): encode/decode-Zeit fuer Container verschiedener
    Groessen (mit und ohne numpy).
  - Source-Handling (A3/A4): Hash-Zeit und Compile-Zeit fuer Skripte.

Aufruf:
    python3 tools/benchmark.py [--count N] [--json]

Ausgabe ist eine Tabelle (oder JSON mit --json), damit Werte zwischen
Laeufen verglichen werden koennen. Alle Zeiten sind Wall-Clock-Sekunden
bzw. Bytes; der Harness laeuft ohne Godot und ohne Netzwerk.

WICHTIG: Dies ist ein Messwerkzeug, keine Garantie fuer Godot-Framezeiten.
Frame-Dekodierzeiten muessen separat im Editor gemessen werden (siehe
docs/BOTTLENECKS.md C1-C4).
"""

import argparse
import hashlib
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent
                       / "addons" / "python_bridge" / "python"))

from python_bridge import protocol, serializer  # noqa: E402


def _timeit(fn, repeats=3):
    best = float("inf")
    for _ in range(repeats):
        t0 = time.perf_counter()
        fn()
        best = min(best, time.perf_counter() - t0)
    return best


def _payload_size_bytes(n, with_numpy):
    """Erzeugt den serialisierten Subbaum inkl. Chunks und gibt die
    Gesamtgroesse der Nachricht zurueck."""
    if with_numpy:
        np = serializer._try_numpy()
        if np is None:
            return None
        value = np.arange(n, dtype=np.float32)
    else:
        value = [float(i) for i in range(n)]
    chunks = []
    enc = serializer.encode_obj(value, chunks)
    head = json.dumps({"v": 2, "type": "task_result", "id": "b", "data": enc})
    total = len(head.encode("utf-8"))
    for chunk in chunks:
        total += 4 + len(chunk)
    return total


def _source_costs(source):
    h = hashlib.sha256
    hash_time = _timeit(lambda: h(source.encode("utf-8")).hexdigest())
    compile_time = _timeit(lambda: compile(source, "<bench>", "exec"))
    return hash_time, compile_time


def run(count, as_json):
    sizes = [100, 10_000, 100_000, 1_000_000]
    results = {"payload_bytes": {}, "sources": {}}

    rows = []
    for n in sizes:
        json_bytes = _payload_size_bytes(n, with_numpy=False)
        np_bytes = _payload_size_bytes(n, with_numpy=True)
        results["payload_bytes"][str(n)] = {
            "json_list_bytes": json_bytes,
            "binary_f32_bytes": np_bytes,
        }
        rows.append({
            "elements": n,
            "json_list_bytes": json_bytes,
            "binary_f32_bytes": np_bytes,
            "ratio": (json_bytes / np_bytes) if json_bytes and np_bytes else None,
        })

    # Source-Kosten: 10 KB, 100 KB, 1 MB Skript
    unit = "def f(x):\n    return x * 2\n\n"
    for label, src in [
        ("10kb", unit * 120),
        ("100kb", unit * 1200),
        ("1mb", unit * 12000),
    ]:
        hash_time, compile_time = _source_costs(src)
        results["sources"][label] = {
            "source_bytes": len(src.encode("utf-8")),
            "sha256_s": round(hash_time, 6),
            "compile_s": round(compile_time, 6),
        }

    if as_json:
        print(json.dumps(results, indent=2))
        return

    print("Python-Bridge Benchmark (Phase 0)")
    print("=" * 72)
    print(f"{'elements':>10} | {'JSON list':>12} | {'binary f32':>12} | {'ratio':>8}")
    print("-" * 72)
    for r in rows:
        ratio = f"{r['ratio']:.1f}x" if r["ratio"] else "n/a"
        jb = r["json_list_bytes"] if r["json_list_bytes"] else "n/a"
        nb = r["binary_f32_bytes"] if r["binary_f32_bytes"] else "numpy fehlt"
        print(f"{r['elements']:>10,} | {jb:>12} | {nb:>12} | {ratio:>8}")
    print("-" * 72)
    print("Source-Kosten (sha256 + compile, jeweils Best-of-3):")
    for label, s in results["sources"].items():
        print(f"  {label:>7}: {s['source_bytes']:>8} B | "
              f"sha256 {s['sha256_s']*1000:7.3f} ms | compile {s['compile_s']*1000:7.3f} ms")
    print("=" * 72)
    print("Hinweis: Verhaeltnis JSON/Binary zeigt den D1-Vorteil roher Bytes.")


def main():
    ap = argparse.ArgumentParser(description="Python Bridge Benchmark Harness")
    ap.add_argument("--count", type=int, default=1_000_000,
                    help="maximale Elementanzahl (Default 1_000_000)")
    ap.add_argument("--json", action="store_true",
                    help="Ausgabe als JSON (fuer CI-Vergleich)")
    args = ap.parse_args()
    run(args.count, args.json)


if __name__ == "__main__":
    main()
