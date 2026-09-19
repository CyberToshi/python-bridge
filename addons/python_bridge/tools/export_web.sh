#!/usr/bin/env bash
# =============================================================================
# Python Bridge - Web-Export in einem Befehl
#
#   ./addons/python_bridge/tools/export_web.sh              -> build/web/
#   ./addons/python_bridge/tools/export_web.sh --serve      -> + Testserver
#   ./addons/python_bridge/tools/export_web.sh --debug      -> Debug-Export
#
# Das Skript prueft alle Voraussetzungen und sagt dir, was fehlt:
#   1. Web-Export-Preset "Web" (Projekt -> Export -> Hinzufuegen -> Web)
#   2. Installierte Export-Templates (Editor -> Exportvorlagen verwalten)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
OUT_DIR="build/web"
PRESET_NAME="${PRESET_NAME:-Web}"
SERVE=false
DEBUG=false

for arg in "$@"; do
  case "$arg" in
    --serve) SERVE=true ;;
    --debug) DEBUG=true ;;
    *) echo "Unbekannte Option: $arg (verfuegbar: --serve, --debug)"; exit 1 ;;
  esac
done

cd "$PROJECT_DIR"
echo "==> Python Bridge Web-Export ($PROJECT_DIR)"

# build/ vom Godot-Import ausschliessen (sonst landen Export-PNGs und
# Bundle-Dateien selbst wieder im PCK) und alte Importartefakte entfernen.
mkdir -p build
touch build/.gdignore
rm -f build/web/index.png.import build/web/index.icon.png.import \
      build/web/index.apple-touch-icon.png.import

# -----------------------------------------------------------------------------
# 1) Godot-CLI finden (natives Binary bevorzugt, Flatpak als Fallback)
# -----------------------------------------------------------------------------
GODOT_CMD=""
if command -v godot >/dev/null 2>&1; then
  GODOT_CMD="godot"
elif command -v godot4 >/dev/null 2>&1; then
  GODOT_CMD="godot4"
elif command -v flatpak >/dev/null 2>&1 && flatpak list --app 2>/dev/null | grep -qi godot; then
  GODOT_CMD="flatpak run --file-forwarding org.godotengine.Godot"
fi
if [ -z "$GODOT_CMD" ]; then
  echo "FEHLER: Kein Godot gefunden (godot/godot4 im PATH oder Godot-Flatpak)."
  exit 1
fi
echo "    Godot: $GODOT_CMD"

if [ ! -f export_presets.cfg ]; then
  echo "FEHLER: Keine export_presets.cfg im Projekt."
  echo "  -> In Godot einmal: Projekt -> Export ... -> Hinzufuegen -> Web"
  echo "     (Preset-Namen auf '$PRESET_NAME' lassen), dann speichern."
  exit 1
fi

TEMPLATES_DIR=""
for cand in \
  "${HOME}/.local/share/godot/export_templates" \
  "${HOME}/.var/app/org.godotengine.Godot/data/godot/export_templates"; do
  if [ -d "$cand" ] && [ -n "$(ls -A "$cand" 2>/dev/null)" ]; then
    TEMPLATES_DIR="$cand"
    break
  fi
done
if [ -z "$TEMPLATES_DIR" ]; then
  echo "FEHLER: Keine Godot-Export-Templates installiert."
  echo "  -> In Godot: Editor -> Exportvorlagen verwalten,"
  echo "     passende Version zur eigenen Godot-Version herunterladen."
  exit 1
fi
echo "    Templates gefunden: $(ls "$TEMPLATES_DIR") (${TEMPLATES_DIR})"
if ! ls "$TEMPLATES_DIR"/*/web_* >/dev/null 2>&1; then
  echo "HINWEIS: Kein Web-Template in den installierten Vorlagen gefunden -"
  echo "  der Export wird trotzdem versucht (Godot meldet Details)."
fi

# -----------------------------------------------------------------------------
# 2) Bridge-Checks + Web-Bundle bauen (aus dem Addon heraus)
# -----------------------------------------------------------------------------
echo "==> Export-Check (web)"
python3 "$SCRIPT_DIR/export_check.py" --project "$PROJECT_DIR" --platform web

echo "==> Bridge-Web-Bundle bauen"
python3 "$SCRIPT_DIR/build_web_bundle.py" \
  --project "$PROJECT_DIR" --out "$OUT_DIR" --packages numpy,scipy,pandas

# -----------------------------------------------------------------------------
# 3) Godot-Web-Export (headless)
# -----------------------------------------------------------------------------
mkdir -p "$OUT_DIR"
EXPORT_PATH="$OUT_DIR/index.html"
if $DEBUG; then
  echo "==> Godot exportiert (debug, headless) ..."
  # shellcheck disable=SC2086
  $GODOT_CMD --headless --export-debug "$PRESET_NAME" "$EXPORT_PATH"
else
  echo "==> Godot exportiert (release, headless) ..."
  # shellcheck disable=SC2086
  $GODOT_CMD --headless --export-release "$PRESET_NAME" "$EXPORT_PATH"
fi

echo "==> Godot-Export-Dateien:"
ls -la "$OUT_DIR" | grep -vE 'bridge_worker|bridge_workspace|bridge_deps|bridge-lock|^total|^d'

# -----------------------------------------------------------------------------
# 4) Fertig - Hinweise
# -----------------------------------------------------------------------------
echo ""
echo "==> Fertig: $OUT_DIR"
echo "    Lokal testen:   cd $OUT_DIR && python3 -m http.server 8000"
echo "                    dann http://localhost:8000 oeffnen (F12-Konsole zeigt"
echo "                    pyodide-Load, workspace-Entpacken, 'bridge host ready')"
echo "    Static Hosting: Inhalt von $OUT_DIR hochladen (z. B. GitHub Pages -"
echo "                    dort ohne 'Thread Support' exportieren)."

if $SERVE; then
  echo ""
  echo "==> Starte Testserver auf http://localhost:8000 (Strg+C beendet)"
  cd "$OUT_DIR"
  python3 -m http.server 8000
fi
