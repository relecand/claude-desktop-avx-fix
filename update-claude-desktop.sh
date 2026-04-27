#!/bin/bash
# update-claude-desktop.sh
# Patches the Claude desktop app to use the npm (Node.js) version of the
# bundled Claude agent SDK CLI instead of the native binary, which crashes on
# older Intel CPUs (pre-AVX2).
#
# Usage: ./update-claude-desktop.sh

set -euo pipefail

CLAUDE_CODE_DIR="$HOME/Library/Application Support/Claude/claude-code"
NVM_DIR="$HOME/.nvm"
LAST_KNOWN_CLI_SDK_VERSION="0.2.112"
CLAUDE_APP_CANDIDATES=(
    "/Applications/Claude.app"
    "$HOME/Applications/Claude.app"
)

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

install_agent_sdk_version() {
    local version="$1"

    echo "Updating @anthropic-ai/claude-agent-sdk@$version via npm..."
    npm install -g "@anthropic-ai/claude-agent-sdk@$version"
}

write_wrapper_script() {
    local binary_path="$1"
    local cli_js="$2"
    local fallback_mode="$3"

    cat > "$binary_path" <<EOF
#!/bin/bash
export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && . "\$NVM_DIR/nvm.sh"

CLI_JS="$cli_js"
FALLBACK_MODE="$fallback_mode"

if [ "\$FALLBACK_MODE" = "1" ]; then
    filtered_args=()

    # Newer Claude Desktop builds pass process-management flags that were added
    # after the last JS CLI release. Drop them so the fallback CLI can still
    # boot and speak stream-json to the desktop app.
    while [ "\$#" -gt 0 ]; do
        case "\$1" in
            --assistant|--assistant=*)
                shift
                continue
                ;;
            --managed-settings)
                shift
                if [ "\$#" -gt 0 ]; then
                    shift
                fi
                continue
                ;;
            --managed-settings=*)
                shift
                continue
                ;;
            --channels)
                shift
                while [ "\$#" -gt 0 ]; do
                    case "\$1" in
                        --*|-*)
                            break
                            ;;
                        *)
                            shift
                            ;;
                    esac
                done
                continue
                ;;
            --channels=*)
                shift
                continue
                ;;
        esac

        filtered_args+=("\$1")
        shift
    done

    exec node "\$CLI_JS" "\${filtered_args[@]}"
fi

exec node "\$CLI_JS" "\$@"
EOF
}

# Load nvm
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

# Check node/npm are available
if ! command -v node &>/dev/null || ! command -v npm &>/dev/null; then
    echo "Error: node/npm not found. Make sure nvm is installed and a node version is active."
    exit 1
fi

NODE_PATH="$(which node)"
echo "Using node: $NODE_PATH ($(node -v))"

# Find the latest version directory in claude-code
if [ ! -d "$CLAUDE_CODE_DIR" ]; then
    echo "Error: Claude code directory not found at $CLAUDE_CODE_DIR"
    echo "Make sure the Claude desktop app is installed."
    exit 1
fi

LATEST_VERSION=$(ls -1 "$CLAUDE_CODE_DIR" | sort -V | tail -1)
if [ -z "$LATEST_VERSION" ]; then
    echo "Error: No version directory found in $CLAUDE_CODE_DIR"
    exit 1
fi

APP_BINARY_PATH="$CLAUDE_CODE_DIR/$LATEST_VERSION/claude.app/Contents/MacOS/claude"
STANDALONE_BINARY_PATH="$CLAUDE_CODE_DIR/$LATEST_VERSION/claude"
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

# Patch both the app bundle binary (used by desktop app) and the standalone binary
for BINARY_PATH in "$APP_BINARY_PATH" "$STANDALONE_BINARY_PATH"; do
    if [ ! -e "$BINARY_PATH" ] && [ ! -L "$BINARY_PATH" ]; then
        echo "Skipping $BINARY_PATH (not found)"
        continue
    fi

    if file "$BINARY_PATH" 2>/dev/null | grep -q "Mach-O"; then
        echo "Backing up native binary: $BINARY_PATH -> ${BINARY_PATH}.bun.bak"
        mv "$BINARY_PATH" "${BINARY_PATH}.bun.bak"
    elif head -1 "$BINARY_PATH" 2>/dev/null | grep -q "^#!/bin/bash"; then
        echo "Existing wrapper found, replacing: $BINARY_PATH"
    fi

    write_wrapper_script "$BINARY_PATH" "$CLI_JS" "$WRAPPER_FALLBACK_MODE"
    chmod +x "$BINARY_PATH"
    echo "Patched: $BINARY_PATH"
done

echo ""
echo "Done! Claude desktop app patched."
echo "  Desktop version dir: $LATEST_VERSION"
echo "  npm agent SDK used:  $NPM_VERSION"
echo "  Requested SDK:       $REQUESTED_AGENT_SDK_VERSION"
echo "  cli.js:              $CLI_JS"
echo "  App binary:          $APP_BINARY_PATH"
echo "  Standalone binary:   $STANDALONE_BINARY_PATH"
echo ""
echo "Restart the Claude desktop app to apply."
