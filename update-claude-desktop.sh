#!/bin/bash
# update-claude-desktop.sh
# Patches the Claude desktop app to use the npm (Node.js) version of claude-code
# instead of the native Bun binary, which crashes on older Intel CPUs (pre-AVX2).
#
# Usage: ./update-claude-desktop.sh

set -e

CLAUDE_CODE_DIR="$HOME/Library/Application Support/Claude/claude-code"
NVM_DIR="$HOME/.nvm"

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

# Update npm package to latest
echo "Updating @anthropic-ai/claude-code via npm..."
npm install -g @anthropic-ai/claude-code@latest

# Find the installed cli.js
CLI_JS="$(npm root -g)/@anthropic-ai/claude-code/cli.js"
if [ ! -f "$CLI_JS" ]; then
    echo "Error: cli.js not found at $CLI_JS"
    exit 1
fi

NPM_VERSION=$(node -e "console.log(require('$(npm root -g)/@anthropic-ai/claude-code/package.json').version)")
echo "npm claude-code version: $NPM_VERSION"

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

    cat > "$BINARY_PATH" << EOF
#!/bin/bash
export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && . "\$NVM_DIR/nvm.sh"
exec node "$CLI_JS" "\$@"
EOF
    chmod +x "$BINARY_PATH"
    echo "Patched: $BINARY_PATH"
done

echo ""
echo "Done! Claude desktop app patched."
echo "  Desktop version dir: $LATEST_VERSION"
echo "  npm claude-code:     $NPM_VERSION"
echo "  App binary:          $APP_BINARY_PATH"
echo "  Standalone binary:   $STANDALONE_BINARY_PATH"
echo ""
echo "Restart the Claude desktop app to apply."
