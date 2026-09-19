#!/usr/bin/env bash
# =============================================================================
# Python Bridge - Plugin-ZIP bauen (fuer Releases / Downloads)
#
#   ./tools/build_plugin_zip.sh [version]
#
# Ergebnis: ~/Downloads/PythonBridge-Plugin-<version>.zip
# Struktur: python_bridge/...  (Extract in den addons/-Ordner des Projekts)
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-$(sed -n 's/^version="\(.*\)"/\1/p' "$REPO_DIR/addons/python_bridge/plugin.cfg")}"
OUT="${OUT:-$HOME/Downloads/PythonBridge-Plugin-${VERSION}.zip}"
STAGE=/tmp/pb_zip_stage

echo "==> Python Bridge Plugin-ZIP v${VERSION} -> ${OUT}"

rm -rf "$STAGE" && mkdir -p "$STAGE/python_bridge"

# 1) Addon-Inhalt
cp -r "$REPO_DIR/addons/python_bridge/." "$STAGE/python_bridge/"

# 2) Docs parallel zum Addon mitliefern (Markdown + HTML-Guide)
mkdir -p "$STAGE/python_bridge/docs"
cp "$REPO_DIR"/docs/*.md "$REPO_DIR"/docs/*.html "$STAGE/python_bridge/docs/" 2>/dev/null || true

# 3) Aufräumen: keine Tests, keine Caches, keine Dev-Reste im Release
rm -rf "$STAGE/python_bridge/tests" "$STAGE/python_bridge/__pycache__" \
       "$STAGE/python_bridge/python/python_bridge/__pycache__"
find "$STAGE" -name '*.pyc' -delete
rm -f "$STAGE/python_bridge/live_e2e_hardening.py"

# 4) Export-Scripts ausführbar markieren
chmod +x "$STAGE"/python_bridge/tools/export_*.sh 2>/dev/null || true

# 5) Packen
rm -f "$OUT"
(cd "$STAGE" && zip -qr "$OUT" python_bridge)

echo "==> Fertig: $(basename "$OUT") ($(unzip -l "$OUT" | tail -1 | awk '{print $2}') Dateien)"
echo "    Installation: ZIP in den addons/-Ordner des Godot-Projekts entpacken"
echo "    (ergibt addons/python_bridge/), dann Plugin aktivieren."
