#!/bin/bash
# install-auto-repatch.sh
# Installs a per-user LaunchAgent that re-runs update-claude-desktop.sh after
# Claude Desktop downloads a fresh Claude Code binary.
#
# Usage:
#   ./install-auto-repatch.sh
#   ./install-auto-repatch.sh --uninstall

set -euo pipefail

LABEL="com.relecand.claude-desktop-avx-fix.repatch"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_SCRIPT="$SCRIPT_DIR/update-claude-desktop.sh"
CLAUDE_CODE_DIR="$HOME/Library/Application Support/Claude/claude-code"
SUPPORT_DIR="$HOME/Library/Application Support/Claude/claude-code-avx-fix"
RUNNER_PATH="$SUPPORT_DIR/auto-repatch.sh"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$LAUNCH_AGENTS_DIR/$LABEL.plist"
LOG_PATH="$HOME/Library/Logs/claude-desktop-avx-fix.log"
LAUNCHD_PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

error() {
    echo "Error: $*" >&2
    exit 1
}

require_command() {
    local command_name="$1"
    local help_text="$2"

    if ! command -v "$command_name" >/dev/null 2>&1; then
        error "$command_name not found. $help_text"
    fi
}

check_macos() {
    if [ "$(uname -s)" != "Darwin" ]; then
        error "This helper is intended for macOS."
    fi
}

unload_agent() {
    local user_id
    user_id="$(id -u)"

    launchctl bootout "gui/$user_id" "$PLIST_PATH" >/dev/null 2>&1 || true
    launchctl unload "$PLIST_PATH" >/dev/null 2>&1 || true
}

check_macos
require_command launchctl "launchctl is required to install the per-user LaunchAgent."

if [ "${1:-}" = "--uninstall" ]; then
    unload_agent
    rm -f "$PLIST_PATH" "$RUNNER_PATH"
    echo "Uninstalled LaunchAgent: $LABEL"
    echo "Log file left in place: $LOG_PATH"
    exit 0
fi

require_command plutil "plutil is required to validate the generated LaunchAgent plist."
require_command strings "strings is required so the auto-repatcher can detect already patched binaries."

if [ ! -x "$PATCH_SCRIPT" ]; then
    echo "Error: patch script not executable: $PATCH_SCRIPT" >&2
    echo "Run: chmod +x update-claude-desktop.sh"
    exit 1
fi

if [ ! -d "$CLAUDE_CODE_DIR" ]; then
    error "Claude code directory not found at $CLAUDE_CODE_DIR. Install and launch Claude Desktop once before installing auto-repatch."
fi

mkdir -p "$SUPPORT_DIR" "$LAUNCH_AGENTS_DIR" "$(dirname "$LOG_PATH")"
touch "$LOG_PATH"

cat > "$RUNNER_PATH" <<EOF
#!/bin/bash
set -euo pipefail

export HOME="$HOME"
export PATH="$LAUNCHD_PATH"

CLAUDE_CODE_DIR="$CLAUDE_CODE_DIR"
PATCH_SCRIPT="$PATCH_SCRIPT"
LOCK_DIR="$SUPPORT_DIR/.auto-repatch.lock"
WRAPPER_MARKER="claude-desktop-avx-fix-mach-o-wrapper"

timestamp() {
    date "+%Y-%m-%d %H:%M:%S"
}

latest_version() {
    ls -1 "\$CLAUDE_CODE_DIR" 2>/dev/null | sort -V | tail -1
}

latest_app_binary() {
    local version
    version="\$(latest_version || true)"

    if [ -z "\$version" ]; then
        return 1
    fi

    printf "%s/%s/claude.app/Contents/MacOS/claude\\n" "\$CLAUDE_CODE_DIR" "\$version"
}

already_patched() {
    local binary_path
    binary_path="\$(latest_app_binary || true)"

    if [ -z "\$binary_path" ] || [ ! -f "\$binary_path" ]; then
        return 1
    fi

    strings "\$binary_path" 2>/dev/null | grep -q "\$WRAPPER_MARKER"
}

if ! mkdir "\$LOCK_DIR" 2>/dev/null; then
    echo "[\$(timestamp)] auto-repatch already running; skipping"
    exit 0
fi

cleanup() {
    rmdir "\$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# Claude Desktop may still be unpacking the new Claude Code bundle when
# WatchPaths fires. Wait briefly so the patch sees a complete version folder.
sleep 20

if already_patched; then
    echo "[\$(timestamp)] latest Claude Code binary already patched; skipping"
    exit 0
fi

echo "[\$(timestamp)] running Claude Desktop AVX re-patch"
"\$PATCH_SCRIPT"
echo "[\$(timestamp)] re-patch finished"
EOF

chmod +x "$RUNNER_PATH"

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>

  <key>ProgramArguments</key>
  <array>
    <string>$RUNNER_PATH</string>
  </array>

  <key>RunAtLoad</key>
  <true/>

  <key>WatchPaths</key>
  <array>
    <string>$CLAUDE_CODE_DIR</string>
  </array>

  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$HOME</string>
    <key>PATH</key>
    <string>$LAUNCHD_PATH</string>
  </dict>

  <key>StandardOutPath</key>
  <string>$LOG_PATH</string>
  <key>StandardErrorPath</key>
  <string>$LOG_PATH</string>
</dict>
</plist>
EOF

plutil -lint "$PLIST_PATH" >/dev/null

unload_agent

USER_ID="$(id -u)"
if launchctl bootstrap "gui/$USER_ID" "$PLIST_PATH" 2>/dev/null; then
    launchctl enable "gui/$USER_ID/$LABEL" >/dev/null 2>&1 || true
    launchctl kickstart -k "gui/$USER_ID/$LABEL" >/dev/null 2>&1 || true
else
    launchctl load "$PLIST_PATH"
fi

echo "Installed LaunchAgent: $PLIST_PATH"
echo "Runner: $RUNNER_PATH"
echo "Log: $LOG_PATH"
echo ""
echo "The patch will run after login and when Claude Desktop updates its Claude Code bundle."
