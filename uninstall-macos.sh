#!/usr/bin/env bash
# uninstall-macos.sh -- remove the clusage menu-bar plugin and its autostart.
# Leaves SwiftBar itself installed (remove with: brew uninstall --cask swiftbar).
set -euo pipefail

PLUGIN_LINK="$HOME/.config/swiftbar/plugins/clusage.60s.py"
AGENT_LABEL="com.clusage.swiftbar"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"

uid="$(id -u)"
launchctl bootout "gui/$uid/$AGENT_LABEL" 2>/dev/null || true
rm -f "$AGENT_PLIST"
rm -f "$PLUGIN_LINK"
rm -rf "$HOME/.cache/clusage"

echo "Removed clusage plugin, autostart LaunchAgent, and cache."
echo "SwiftBar is still installed (brew uninstall --cask swiftbar to remove it)."
