#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Python Bridge Worker - Starter fuer Linux (Doppelklick oder ./start_worker_linux.sh)
#  Nutzt das Projekt-venv, falls vorhanden, sonst das System-Python 3.
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

PY=""
for candidate in \
    "../../../../python_bridge/venv/bin/python" \
    "../venv/bin/python" \
    "./.venv/bin/python"; do
    if [ -x "$candidate" ]; then
        PY="$candidate"
        break
    fi
done
if [ -z "$PY" ]; then
    if command -v python3 >/dev/null 2>&1; then
        PY="python3"
    else
        echo "Python 3 wurde nicht gefunden. Bitte installieren (inkl. python3-tk)." >&2
        exit 1
    fi
fi

exec "$PY" worker_app.py "$@"
