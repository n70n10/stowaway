#!/usr/bin/env bash
set -euo pipefail

BOLD="\033[1m"
RESET="\033[0m"
PINK="\033[38;2;235;111;146m"
FOAM="\033[38;2;156;207;216m"
GOLD="\033[38;2;246;193;119m"
IRIS="\033[38;2;196;167;231m"

say()  { echo -e "${FOAM}${BOLD}=>${RESET} $*"; }
ok()   { echo -e "${IRIS}  ✓${RESET} $*"; }
warn() { echo -e "${GOLD}  !${RESET} $*"; }
die()  { echo -e "${PINK}${BOLD}  ✗ Error:${RESET} $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo -e "\n${PINK}${BOLD}  Rosé Pine${RESET} for KDE Plasma\n"

# --- Plasma color scheme ---
say "Installing Plasma color scheme..."
PLASMA_DIR="$HOME/.local/share/color-schemes"
mkdir -p "$PLASMA_DIR"
cp "$SCRIPT_DIR/rose-pine.colors" "$PLASMA_DIR/rose-pine.colors"
ok "RosePine.colors → $PLASMA_DIR"

# --- Konsole color scheme ---
say "Installing Konsole color scheme..."
KONSOLE_DIR="$HOME/.local/share/konsole"
mkdir -p "$KONSOLE_DIR"
cp "$SCRIPT_DIR/rose-pine.colorscheme" "$KONSOLE_DIR/rose-pine.colorscheme"
ok "RosePine.colorscheme → $KONSOLE_DIR"

# --- Kate / KSyntaxHighlighting theme ---
say "Installing Kate syntax highlighting theme..."
KATE_DIR="$HOME/.local/share/org.kde.syntax-highlighting/themes"
mkdir -p "$KATE_DIR"
cp "$SCRIPT_DIR/rose-pine.theme" "$KATE_DIR/rose-pine.theme"
ok "rose-pine.theme → $KATE_DIR"

# --- Apply Plasma color scheme automatically if plasma-apply-colorscheme is available ---
echo ""
if command -v plasma-apply-colorscheme &>/dev/null; then
    say "Applying Plasma color scheme..."
    if plasma-apply-colorscheme RosePine 2>/dev/null; then
        ok "Plasma color scheme applied!"
    else
        warn "Could not apply automatically — select 'Rosé Pine' in System Settings → Colors & Themes → Colors"
    fi
else
    warn "plasma-apply-colorscheme not found — select 'Rosé Pine' manually in System Settings → Colors & Themes → Colors"
fi

echo ""
echo -e "${IRIS}${BOLD}  Done!${RESET} Remaining manual steps:"
echo -e "  ${FOAM}Konsole${RESET}  Settings → Edit Current Profile → Appearance → Rosé Pine"
echo -e "  ${FOAM}Kate${RESET}     Settings → Configure Kate → Fonts & Colors → Rosé Pine"
echo ""
