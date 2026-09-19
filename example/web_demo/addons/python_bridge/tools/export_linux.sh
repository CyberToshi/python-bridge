#!/usr/bin/env bash
# =============================================================================
# Python Bridge - Linux-Desktop-Export in einem Befehl
#
#   ./addons/python_bridge/tools/export_linux.sh
#
# Prueft Voraussetzungen, laesst den Bridge-Export-Check laufen und exportiert
# headless nach build/linux/. Preset/Name ueber Umgebungsvariablen anpassbar:
#   PRESET_NAME=Linux BIN_NAME=MeinSpiel.x86_64 ./addons/python_bridge/tools/export_linux.sh
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PRESET_NAME="${PRESET_NAME:-Linux}"
OUT_DIR="$PROJECT_DIR/build/linux"

# Projektname aus project.godot lesen (config/name), falls BIN_NAME nicht
# gesetzt ist - "Mein Spiel" wird zu "MeinSpiel".
if [ -z "${BIN_NAME:-}" ]; then
  RAW_NAME="$(sed -n 's/^config\/name="\(.*\)"/\1/p' "$PROJECT_DIR/project.godot" | head -n1)"
  [ -n "$RAW_NAME" ] || RAW_NAME="Game"
  BIN_NAME="$(echo "$RAW_NAME" | tr -cd 'A-Za-z0-9_-').x86_64"
fi

echo "==> Python Bridge Linux-Export ($PROJECT_DIR)"

# 1) Godot-CLI finden
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

# 2) Export-Templates
TPL_DIR="$HOME/.local/share/godot/export_templates"
[ -d "$TPL_DIR" ] || TPL_DIR="$HOME/.var/app/org.godotengine.Godot/data/godot/export_templates"
TPL_VER="$(ls "$TPL_DIR" 2>/dev/null | sort -V | tail -n1 || true)"
if [ -z "$TPL_VER" ]; then
    echo "FEHLER: Keine Godot-Export-Templates installiert."
    echo "  -> In Godot: Editor -> Exportvorlagen verwalten, passende"
    echo "     Version herunterladen (muss zur Godot-Version passen)."
    exit 1
fi
echo "    Templates gefunden: $TPL_VER ($TPL_DIR)"

# 3) Bridge-Export-Check (linux): muss ohne Fehler durchgehen
echo "==> Export-Check (linux)"
python3 "$SCRIPT_DIR/export_check.py" --project "$PROJECT_DIR" --platform linux

# 4) Export (headless)
echo "==> Godot exportiert (headless) ..."
mkdir -p "$OUT_DIR"
# shellcheck disable=SC2086
$GODOT_CMD --headless --export-release "$PRESET_NAME" "$OUT_DIR/$BIN_NAME"

echo "==> Export-Dateien:"
ls -la "$OUT_DIR"

echo "==> Fertig: build/linux"
echo "    Testen (mit sichtbarer Konsole):"
echo "        $OUT_DIR/$BIN_NAME"
echo "    Erster Start: Provisionierung baut venv inkl. __bridge_deps__"
echo "    - je nach Netz 1-5 Minuten, Log zeigt [PROV]."
