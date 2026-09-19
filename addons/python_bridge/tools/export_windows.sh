#!/usr/bin/env bash
# =============================================================================
# Python Bridge - Windows-Desktop-Export in einem Befehl
#
#   ./addons/python_bridge/tools/export_windows.sh
#
# Cross-Compile von Linux: Godot baut die Windows-.exe direkt, Wine wird nur
# fuer Icon/Version-Infos im PE-Header benoetigt. Auf echter Windows-Hardware
# einfach Godot dort installieren, Preset "Windows Desktop" anlegen und das
# Skript gleich mitlaufen lassen (gleiche Pruefkette).
#   PRESET_NAME="Windows Desktop" BIN_NAME=MeinSpiel.exe ...
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PRESET_NAME="${PRESET_NAME:-Windows Desktop}"
OUT_DIR="$PROJECT_DIR/build/windows"

if [ -z "${BIN_NAME:-}" ]; then
  RAW_NAME="$(sed -n 's/^config\/name="\(.*\)"/\1/p' "$PROJECT_DIR/project.godot" | head -n1)"
  [ -n "$RAW_NAME" ] || RAW_NAME="Game"
  BIN_NAME="$(echo "$RAW_NAME" | tr -cd 'A-Za-z0-9_-').exe"
fi

echo "==> Python Bridge Windows-Export ($PROJECT_DIR)"

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

# 2) Export-Templates (Web/Linux pruefen Dateien; hier muss windows_* da sein)
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
if ! ls "$TPL_DIR"/*/windows_* >/dev/null 2>&1; then
    echo "FEHLER: Kein Windows-Template in den installierten Vorlagen gefunden."
    echo "  -> Vorlagen-Paket muss windows_template_x86_64 (release/debug) enthalten."
    exit 1
fi

# 3) Wine-Hinweis (nur fuer Icon/Version-Patching noetig; Export kann trotzdem
#    gelingen, wenn default-icon/-version akzeptiert werden)
if ! command -v wine >/dev/null 2>&1 && [ "$(uname -s)" = "Linux" ]; then
  echo "HINWEIS: Wine nicht gefunden. Godot braucht es auf Linux nur fuer"
  echo "  Icon-/Version-Aenderungen an der .exe - ohne Wine wird der Export"
  echo "  mit Standard-Icon versucht oder bricht mit Fehler ab (Godot meldet es)."
fi

# 4) Bridge-Export-Check (linux/desktop-Features gelten fuer den Build-Host)
echo "==> Export-Check (linux)"
python3 "$SCRIPT_DIR/export_check.py" --project "$PROJECT_DIR" --platform linux

# 5) Export (headless)
echo "==> Godot exportiert (headless) ..."
mkdir -p "$OUT_DIR"
# shellcheck disable=SC2086
$GODOT_CMD --headless --export-release "$PRESET_NAME" "$OUT_DIR/$BIN_NAME"

echo "==> Export-Dateien:"
ls -la "$OUT_DIR"

echo "==> Fertig: build/windows"
echo "    Die .exe + .pck auf Windows uebertragen und dort testen."
echo "    Erster Start: Provisionierung baut die venv inkl. __bridge_deps__"
echo "    - je nach Netz/Defender 2-5 Minuten, Log zeigt [PROV]."
