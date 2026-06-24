#!/bin/bash
# update-claude-desktop.sh
# Patches the Claude desktop app to use the npm (Node.js) version of the
# bundled Claude agent SDK CLI instead of the native binary, which crashes on
# older Intel CPUs (pre-AVX2).
#
# Usage: ./update-claude-desktop.sh

set -euo pipefail

CLAUDE_CODE_DIR="$HOME/Library/Application Support/Claude/claude-code"
LOCAL_OVERRIDE_DIR="$HOME/Library/Application Support/Claude/claude-code-avx-fix"
LOCAL_OVERRIDE_BINARY_PATH="$LOCAL_OVERRIDE_DIR/claude"
NVM_DIR="$HOME/.nvm"
LAST_KNOWN_CLI_SDK_VERSION="0.2.112"
CLAUDE_APP_CANDIDATES=(
    "/Applications/Claude.app"
    "$HOME/Applications/Claude.app"
)

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
        error "This script is intended for macOS."
    fi
}

check_npm_global_prefix_writable() {
    local npm_prefix
    local check_path

    npm_prefix="$(npm config get prefix 2>/dev/null || true)"
    if [ -z "$npm_prefix" ] || [ "$npm_prefix" = "undefined" ]; then
        error "Could not read npm's global prefix. Check your Node.js/npm installation."
    fi

    check_path="$npm_prefix"
    while [ ! -e "$check_path" ] && [ "$check_path" != "/" ]; do
        check_path="$(dirname "$check_path")"
    done

    if [ ! -w "$check_path" ]; then
        cat >&2 <<EOF
Error: npm's global prefix is not writable: $npm_prefix
Set a user-writable npm prefix, for example:
  npm config set prefix ~/.local
Then make sure ~/.local/bin is on your PATH.
EOF
        exit 1
    fi
}

run_preflight_checks() {
    check_macos
    require_command node "Install Node.js first; nvm works well, but is not required."
    require_command npm "Install npm with Node.js first."
    require_command clang "Install Xcode Command Line Tools: xcode-select --install"
    require_command file "The macOS file utility is required."
    require_command strings "The macOS strings utility is required."
    check_npm_global_prefix_writable
}

find_claude_app_asar() {
    local app_path
    local asar_path

    for app_path in "${CLAUDE_APP_CANDIDATES[@]}"; do
        asar_path="$app_path/Contents/Resources/app.asar"
        if [ -f "$asar_path" ]; then
            printf '%s\n' "$asar_path"
            return 0
        fi
    done

    return 1
}

read_agent_sdk_version_from_asar() {
    local asar_path="$1"

    node - "$asar_path" <<'NODE'
const fs = require('fs')

const asarPath = process.argv[2]
const contents = fs.readFileSync(asarPath, 'utf8')
const match = contents.match(/"@anthropic-ai\/claude-agent-sdk":\s*"([^"]+)"/)

if (match) {
  process.stdout.write(match[1])
}
NODE
}

infer_agent_sdk_version() {
    local desktop_version="$1"
    local build_number="${desktop_version##*.}"

    if [[ "$build_number" =~ ^[0-9]+$ ]]; then
        printf '0.2.%s\n' "$build_number"
    fi
}

resolve_cli_js_path() {
    local npm_root="$1"
    local candidate

    for candidate in \
        "$npm_root/@anthropic-ai/claude-agent-sdk/cli.js" \
        "$npm_root/@anthropic-ai/claude-code/cli.js"; do
        if [ -f "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

is_installed_wrapper() {
    local binary_path="$1"

    strings "$binary_path" 2>/dev/null | grep -Eq "claude-desktop-avx-fix-mach-o-wrapper|@anthropic-ai/claude-agent-sdk/cli.js"
}

install_agent_sdk_version() {
    local version="$1"

    echo "Updating @anthropic-ai/claude-agent-sdk@$version via npm..."
    npm install -g "@anthropic-ai/claude-agent-sdk@$version"
}

write_wrapper_script() {
    local binary_path="$1"
    local cli_js="$2"
    local fallback_mode="$3"
    local node_bin="$4"
    local tmp_dir
    local source_path
    local node_literal
    local cli_literal

    if ! command -v clang >/dev/null 2>&1; then
        echo "Error: clang not found. Install Xcode Command Line Tools to build the Mach-O wrapper."
        exit 1
    fi

    tmp_dir="$(mktemp -d)"
    source_path="$tmp_dir/claude-avx-wrapper.c"
    node_literal="$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$node_bin")"
    cli_literal="$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$cli_js")"

    cat > "$source_path" <<EOF
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char *NODE_BIN = $node_literal;
static const char *CLI_JS = $cli_literal;
static const char *WRAPPER_MARKER = "claude-desktop-avx-fix-mach-o-wrapper";
static const int FALLBACK_MODE = $fallback_mode;

static int starts_with(const char *value, const char *prefix) {
    return strncmp(value, prefix, strlen(prefix)) == 0;
}

static int is_flag(const char *value) {
    return value != NULL && value[0] == '-';
}

int main(int argc, char **argv) {
    const char *node_bin = NODE_BIN;

    if (access(node_bin, X_OK) != 0) {
        fprintf(stderr, "Error: node not found. Expected node at %s\\n", NODE_BIN);
        return 127;
    }

    char **filtered_args = calloc((size_t)argc + 2, sizeof(char *));
    if (filtered_args == NULL) {
        fprintf(stderr, "Error: failed to allocate argument list (%s)\\n", WRAPPER_MARKER);
        return 126;
    }

    int output_index = 0;
    filtered_args[output_index++] = (char *)node_bin;
    filtered_args[output_index++] = (char *)CLI_JS;

    for (int input_index = 1; input_index < argc; input_index++) {
        char *arg = argv[input_index];

        if (FALLBACK_MODE) {
            if (strcmp(arg, "--assistant") == 0 || starts_with(arg, "--assistant=")) {
                continue;
            }
            if (strcmp(arg, "--managed-settings") == 0) {
                if (input_index + 1 < argc) {
                    input_index++;
                }
                continue;
            }
            if (starts_with(arg, "--managed-settings=")) {
                continue;
            }
            if (strcmp(arg, "--channels") == 0) {
                input_index++;
                while (input_index < argc) {
                    if (is_flag(argv[input_index])) {
                        input_index--;
                        break;
                    }
                    input_index++;
                }
                continue;
            }
            if (starts_with(arg, "--channels=")) {
                continue;
            }
        }

        filtered_args[output_index++] = arg;
    }

    filtered_args[output_index] = NULL;
    execv(node_bin, filtered_args);
    fprintf(stderr, "Error: failed to exec %s: %s\\n", node_bin, strerror(errno));
    return errno == ENOENT ? 127 : 126;
}
EOF

    clang -arch x86_64 -mmacosx-version-min=10.13 -O2 -mno-avx -mno-avx2 "$source_path" -o "$binary_path"
    rm -rf "$tmp_dir"
}

# Load nvm
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

run_preflight_checks

NODE_PATH="$(which node)"
echo "Using node: $NODE_PATH ($(node -v))"

# Find the latest version directory in claude-code
if [ ! -d "$CLAUDE_CODE_DIR" ]; then
    error "Claude code directory not found at $CLAUDE_CODE_DIR. Install and launch Claude Desktop once before running this patch."
fi

LATEST_VERSION=$(ls -1 "$CLAUDE_CODE_DIR" | sort -V | tail -1)
if [ -z "$LATEST_VERSION" ]; then
    error "No version directory found in $CLAUDE_CODE_DIR. Launch Claude Desktop once so it downloads Claude Code."
fi

APP_BINARY_PATH="$CLAUDE_CODE_DIR/$LATEST_VERSION/claude.app/Contents/MacOS/claude"
STANDALONE_BINARY_PATH="$CLAUDE_CODE_DIR/$LATEST_VERSION/claude"
VERIFIED_MARKER_PATH="$CLAUDE_CODE_DIR/$LATEST_VERSION/.verified"
echo "Found desktop claude-code version: $LATEST_VERSION"

CLAUDE_APP_ASAR=""
if CLAUDE_APP_ASAR="$(find_claude_app_asar)"; then
    echo "Found Claude Desktop app bundle: $CLAUDE_APP_ASAR"
else
    echo "Warning: Could not find Claude.app in /Applications or \$HOME/Applications."
fi

AGENT_SDK_VERSION=""
if [ -n "$CLAUDE_APP_ASAR" ]; then
    AGENT_SDK_VERSION="$(read_agent_sdk_version_from_asar "$CLAUDE_APP_ASAR" || true)"
fi

if [ -z "$AGENT_SDK_VERSION" ]; then
    AGENT_SDK_VERSION="$(infer_agent_sdk_version "$LATEST_VERSION" || true)"
    if [ -n "$AGENT_SDK_VERSION" ]; then
        echo "Warning: Could not read bundled @anthropic-ai/claude-agent-sdk version from app.asar."
        echo "         Falling back to inferred SDK version: $AGENT_SDK_VERSION"
    else
        echo "Error: Could not determine which @anthropic-ai/claude-agent-sdk version to install."
        exit 1
    fi
else
    echo "Bundled agent SDK version: $AGENT_SDK_VERSION"
fi

REQUESTED_AGENT_SDK_VERSION="$AGENT_SDK_VERSION"
SELECTED_AGENT_SDK_VERSION="$REQUESTED_AGENT_SDK_VERSION"

install_agent_sdk_version "$SELECTED_AGENT_SDK_VERSION"

NPM_ROOT="$(npm root -g)"

# Find the installed cli.js
CLI_JS="$(resolve_cli_js_path "$NPM_ROOT" || true)"
if [ -z "$CLI_JS" ] && [ "$SELECTED_AGENT_SDK_VERSION" != "$LAST_KNOWN_CLI_SDK_VERSION" ]; then
    echo "Warning: @anthropic-ai/claude-agent-sdk@$SELECTED_AGENT_SDK_VERSION no longer ships cli.js."
    echo "         Falling back to last known JS CLI build: $LAST_KNOWN_CLI_SDK_VERSION"

    SELECTED_AGENT_SDK_VERSION="$LAST_KNOWN_CLI_SDK_VERSION"
    install_agent_sdk_version "$SELECTED_AGENT_SDK_VERSION"

    NPM_ROOT="$(npm root -g)"
    CLI_JS="$(resolve_cli_js_path "$NPM_ROOT" || true)"
fi

if [ -z "$CLI_JS" ]; then
    echo "Error: cli.js not found under $NPM_ROOT"
    echo "       Requested SDK version: $REQUESTED_AGENT_SDK_VERSION"
    echo "       Fallback SDK version:  $LAST_KNOWN_CLI_SDK_VERSION"
    exit 1
fi

NPM_VERSION=$(node -e "console.log(require(process.argv[1]).version)" "$NPM_ROOT/@anthropic-ai/claude-agent-sdk/package.json")
echo "npm agent SDK version used: $NPM_VERSION"
if [ "$REQUESTED_AGENT_SDK_VERSION" != "$NPM_VERSION" ]; then
    echo "Requested agent SDK version: $REQUESTED_AGENT_SDK_VERSION"
fi

WRAPPER_FALLBACK_MODE="0"
if [ "$REQUESTED_AGENT_SDK_VERSION" != "$NPM_VERSION" ]; then
    WRAPPER_FALLBACK_MODE="1"
    echo "Wrapper compatibility mode: enabled"
fi

mkdir -p "$LOCAL_OVERRIDE_DIR"
write_wrapper_script "$LOCAL_OVERRIDE_BINARY_PATH" "$CLI_JS" "$WRAPPER_FALLBACK_MODE" "$NODE_PATH"
chmod +x "$LOCAL_OVERRIDE_BINARY_PATH"
echo "Installed local override wrapper: $LOCAL_OVERRIDE_BINARY_PATH"

if command -v launchctl >/dev/null 2>&1; then
    USER_ID="$(id -u)"
    if launchctl asuser "$USER_ID" launchctl setenv CLAUDE_CODE_LOCAL_BINARY "$LOCAL_OVERRIDE_BINARY_PATH"; then
        echo "Set GUI launchd environment: CLAUDE_CODE_LOCAL_BINARY=$LOCAL_OVERRIDE_BINARY_PATH"
    else
        launchctl setenv CLAUDE_CODE_LOCAL_BINARY "$LOCAL_OVERRIDE_BINARY_PATH"
        echo "Set launchd environment: CLAUDE_CODE_LOCAL_BINARY=$LOCAL_OVERRIDE_BINARY_PATH"
    fi
else
    echo "Warning: launchctl not found. Set CLAUDE_CODE_LOCAL_BINARY manually before launching Claude Desktop."
fi

# Patch both the app bundle binary (used by desktop app) and the standalone binary
for BINARY_PATH in "$APP_BINARY_PATH" "$STANDALONE_BINARY_PATH"; do
    if [ ! -e "$BINARY_PATH" ] && [ ! -L "$BINARY_PATH" ]; then
        echo "Skipping $BINARY_PATH (not found)"
        continue
    fi

    if file "$BINARY_PATH" 2>/dev/null | grep -q "Mach-O"; then
        if is_installed_wrapper "$BINARY_PATH"; then
            echo "Existing Mach-O wrapper found, replacing: $BINARY_PATH"
        elif [ -e "${BINARY_PATH}.bun.bak" ]; then
            echo "Native binary backup already exists: ${BINARY_PATH}.bun.bak"
        else
            echo "Backing up native binary: $BINARY_PATH -> ${BINARY_PATH}.bun.bak"
            mv "$BINARY_PATH" "${BINARY_PATH}.bun.bak"
        fi
    elif head -1 "$BINARY_PATH" 2>/dev/null | grep -q "^#!/bin/bash"; then
        echo "Existing wrapper found, replacing: $BINARY_PATH"
    fi

    write_wrapper_script "$BINARY_PATH" "$CLI_JS" "$WRAPPER_FALLBACK_MODE" "$NODE_PATH"
    chmod +x "$BINARY_PATH"
    echo "Patched: $BINARY_PATH"
done

touch "$VERIFIED_MARKER_PATH"
echo "Ensured verified marker: $VERIFIED_MARKER_PATH"

echo ""
echo "Done! Claude desktop app patched."
echo "  Desktop version dir: $LATEST_VERSION"
echo "  npm agent SDK used:  $NPM_VERSION"
echo "  Requested SDK:       $REQUESTED_AGENT_SDK_VERSION"
echo "  cli.js:              $CLI_JS"
echo "  Local override:      $LOCAL_OVERRIDE_BINARY_PATH"
echo "  App binary:          $APP_BINARY_PATH"
echo "  Standalone binary:   $STANDALONE_BINARY_PATH"
echo ""
echo "Restart the Claude desktop app to apply."
