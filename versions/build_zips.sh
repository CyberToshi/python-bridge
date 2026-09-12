#!/usr/bin/env bash
# Baut die Auslieferungs-ZIPs reproduzierbar aus dem Projektstand.
#
#   ./versions/build_zips.sh
#
# Ergebnis (jeweils neu geschrieben):
#   versions/PythonBridge-Plugin-<version>.zip    Manager/Godot-Addon
#   versions/PythonBridge-Worker-<version>.zip    Client-Programm (Worker)
#   versions/SHA256SUMS.txt                       Pruefsummen beider Pakete
#
# Bewusst NICHT enthalten: Beispiele, Tests, venv, Caches, .godot,
# Projektdateien, Logs - und keine Dateien mit Geheimnissen (Token).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSIONS_DIR="$ROOT/versions"
VERSION="$(tr -d '[:space:]' < "$VERSIONS_DIR/VERSION")"
if [ -z "$VERSION" ]; then
  echo "versions/VERSION ist leer." >&2
  exit 1
fi

PLUGIN_ZIP="$VERSIONS_DIR/PythonBridge-Plugin-$VERSION.zip"
WORKER_ZIP="$VERSIONS_DIR/PythonBridge-Worker-$VERSION.zip"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# Von allem, was nie in ein Paket gehoert, eine Liste zum Ausschliessen bauen.
EXCLUDES=(-x "*/venv/*" -x "*/__pycache__/*" -x "*.pyc" -x "*.pyo"
          -x "*.log" -x "*/worker_config.json" -x "*/orchestrator_workers.json"
          -x "*/logs/*" -x "*/.DS_Store" -x "*.part" -x "*.tmp")
CLEAN_DIRS=(venv __pycache__ .git .godot)

clean_tree() {
  local target="$1"
  for name in "${CLEAN_DIRS[@]}"; do
    find "$target" -type d -name "$name" -prune -exec rm -rf {} + 2>/dev/null || true
  done
  find "$target" -type f \( -name "*.pyc" -o -name "*.pyo" -o -name "*.log" \
       -o -name "worker_config.json" -o -name "orchestrator_workers.json" \
       -o -name "*.part" \) -delete 2>/dev/null || true
}

# ---------------------------------------------------------------- Plugin
PLUGIN_ROOT="$STAGE/plugin"
mkdir -p "$PLUGIN_ROOT/addons"
cp -r "$ROOT/addons/python_bridge" "$PLUGIN_ROOT/addons/python_bridge"
clean_tree "$PLUGIN_ROOT"

echo "[build] Plugin: $(find "$PLUGIN_ROOT" -type f | wc -l) Dateien"
rm -f "$PLUGIN_ZIP"
( cd "$PLUGIN_ROOT" && zip -rq "$PLUGIN_ZIP" addons "${EXCLUDES[@]}" )

# ---------------------------------------------------------------- Worker
WORKER_ROOT="$STAGE/worker/PythonBridge-Worker"
mkdir -p "$WORKER_ROOT"
WORKER_DIR="$ROOT/addons/python_bridge/orchestrator/worker"
cp "$WORKER_DIR/orchestrator_worker.py" "$WORKER_DIR/worker_app.py" \
   "$WORKER_DIR/python_build.py" "$WORKER_DIR/file_store.py" \
   "$WORKER_DIR/tls_cert.py" \
   "$WORKER_DIR/worker.spec" "$WORKER_DIR/LIESMICH.txt" \
   "$WORKER_DIR/Worker-Windows.bat" "$WORKER_DIR/start_worker_linux.sh" \
   "$WORKER_ROOT/"
cp "$ROOT/addons/python_bridge/orchestrator/CLUSTER_V1_SETUP.md" \
   "$ROOT/addons/python_bridge/orchestrator/SAFETY.md" \
   "$ROOT/addons/python_bridge/orchestrator/CYTHON_AND_BUILD.md" \
   "$WORKER_ROOT/"
chmod +x "$WORKER_ROOT/start_worker_linux.sh"
clean_tree "$WORKER_ROOT"
# Sicherheitsnetz: ohne Token-Datei, aber mit Anleitung.
if [ -e "$WORKER_ROOT/worker_config.json" ]; then
  echo "FEHLER: worker_config.json darf nicht ins Paket (enthaelt das Token)." >&2
  exit 1
fi

# Sicherheitsnetz: die Module, ohne die der Worker gar nicht startet, muessen
# im Paket liegen (der Worker bricht sonst mit Fehlercode 2 ab).
for required in orchestrator_worker.py worker_app.py python_build.py \
                file_store.py tls_cert.py LIESMICH.txt; do
  if [ ! -f "$WORKER_ROOT/$required" ]; then
    echo "FEHLER: $required fehlt im Worker-Paket." >&2
    exit 1
  fi
done
if ! command -v python3 >/dev/null 2>&1 \
   || ! python3 -c "import ast,sys,pathlib; [ast.parse(pathlib.Path(p).read_text(encoding='utf-8')) for p in sys.argv[1:]]" \
        "$WORKER_ROOT"/*.py 2>/dev/null; then
  echo "[build] Hinweis: Python-Syntaxpruefung uebersprungen."
fi

echo "[build] Worker: $(find "$WORKER_ROOT" -type f | wc -l) Dateien"
rm -f "$WORKER_ZIP"
( cd "$STAGE/worker" && zip -rq "$WORKER_ZIP" PythonBridge-Worker "${EXCLUDES[@]}" )

# ---------------------------------------------------------------- Pruefsummen
( cd "$VERSIONS_DIR" && sha256sum "$(basename "$PLUGIN_ZIP")" "$(basename "$WORKER_ZIP")" \
    > SHA256SUMS.txt )

echo "[build] Fertig:"
ls -la "$PLUGIN_ZIP" "$WORKER_ZIP" "$VERSIONS_DIR/SHA256SUMS.txt"
echo "[build] Inhalt pruefen:  unzip -l <zip>"
