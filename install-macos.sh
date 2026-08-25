#!/usr/bin/env bash
# install-macos.sh -- install the clusage Claude Code usage indicator into the
# macOS menu bar via SwiftBar, and autostart it at login.
#
# Idempotent: safe to re-run to pick up edits to ./clusage-swiftbar.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_SRC="$REPO_DIR/clusage-swiftbar"
PLUGIN_DIR="$HOME/.config/swiftbar/plugins"
PLUGIN_LINK="$PLUGIN_DIR/clusage.60s.py"   # SwiftBar reads the 60s refresh from the name
SB_DOMAIN="com.ameba.SwiftBar"
AGENT_LABEL="com.clusage.swiftbar"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"

echo "==> clusage macOS install"

# 1. SwiftBar (the menu-bar host; the macOS analog to Waybar).
if [ ! -d "/Applications/SwiftBar.app" ]; then
    echo "--> installing SwiftBar via Homebrew"
    brew install --cask swiftbar
else
    echo "--> SwiftBar already installed"
fi

# 2. Plugin: symlink the repo script into SwiftBar's plugin folder so the repo
#    stays the source of truth (edits take effect on the next refresh).
mkdir -p "$PLUGIN_DIR"
chmod +x "$SCRIPT_SRC"
ln -sf "$SCRIPT_SRC" "$PLUGIN_LINK"
echo "--> plugin: $PLUGIN_LINK -> $SCRIPT_SRC"

# 3. Point SwiftBar at that folder (set before first launch to skip onboarding).
defaults write "$SB_DOMAIN" PluginDirectory -string "$PLUGIN_DIR"
echo "--> SwiftBar PluginDirectory set to $PLUGIN_DIR"

# 4. Autostart at login via a LaunchAgent, and launch now.
cp "$REPO_DIR/$AGENT_LABEL.plist" "$AGENT_PLIST"
uid="$(id -u)"
launchctl bootout "gui/$uid/$AGENT_LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$uid" "$AGENT_PLIST" 2>/dev/null || launchctl load -w "$AGENT_PLIST"
echo "--> autostart LaunchAgent installed: $AGENT_PLIST"

# Ensure it's up right now (bootstrap's RunAtLoad also does this on a fresh load).
open -gja SwiftBar || true

echo
echo "Done. The ◔ indicator should appear in your menu bar within a few seconds."
echo "If SwiftBar asks for a plugins folder, choose: $PLUGIN_DIR"
echo
echo "Uninstall:  $REPO_DIR/uninstall-macos.sh"
