#!/bin/bash
# update-claude-desktop.sh
#
# Makes Claude Desktop usable on Intel Macs whose CPU lacks AVX2, where the
# bundled Claude Code binary dies during dynamic-library initialisation with:
#
#     Illegal instruction: 4        (SIGILL / EXC_BAD_INSTRUCTION)
#
# The Electron window opens, but the agent backend is dead, so the app never
# answers anything.
#
# Strategy, in order:
#   1. Probe the binary Claude Desktop just downloaded. If it runs, you are not
#      affected and nothing is changed.
#   2. Otherwise install the npm-published `@anthropic-ai/claude-code` build for
#      the same version. Those builds are compiled for a lower CPU baseline and
#      run on pre-AVX2 hardware.
#   3. If that build also faults, try the newest published build.
#   4. Last resort, for CPUs without even AVX1: build a tiny Mach-O launcher
#      that runs the JavaScript CLI (`cli.js`) under Node.js.
#
# Usage:
#   ./update-claude-desktop.sh              patch if needed
#   ./update-claude-desktop.sh --check      diagnose only, change nothing
#   ./update-claude-desktop.sh --force      patch even if the binary looks fine
#   ./update-claude-desktop.sh --restore    undo the patch
#   ./update-claude-desktop.sh --pin X.Y.Z  use a specific claude-code version
#   ./update-claude-desktop.sh --help
#
# Exit codes:
#   0  nothing to do / success
#   1  error
#   2  (--check only) the patch is needed

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

CLAUDE_SUPPORT_DIR="$HOME/Library/Application Support/Claude"
CLAUDE_CODE_DIR="$CLAUDE_SUPPORT_DIR/claude-code"
FIX_DIR="$CLAUDE_SUPPORT_DIR/claude-code-avx-fix"
OVERRIDE_BINARY="$FIX_DIR/claude"
STATE_FILE="$FIX_DIR/patch-state"
CACHE_DIR="$FIX_DIR/cache"

REGISTRY="${CLAUDE_AVX_FIX_REGISTRY:-https://registry.npmjs.org}"
WRAPPER_PKG="@anthropic-ai/claude-code"
AGENT_SDK_PKG="@anthropic-ai/claude-agent-sdk"
# Last agent-SDK release that still shipped a runnable cli.js, used only by the
# Node.js fallback for CPUs that cannot run the native builds at all.
LAST_KNOWN_CLI_SDK_VERSION="0.2.112"

NVM_DIR="$HOME/.nvm"
WRAPPER_MARKER="claude-desktop-avx-fix-mach-o-wrapper"
SIGILL_STATUS=132
PROBE_TIMEOUT=60

MODE="patch"
FORCE="false"
PINNED_VERSION=""

# ---------------------------------------------------------------- output ------

log()  { printf '%s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
error() { printf 'Error: %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '4,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ------------------------------------------------------------- utilities -----

# Run a command with a hard wall-clock limit. macOS has no coreutils `timeout`.
run_with_timeout() {
    local seconds="$1"
    shift

    local pid watcher status=0
    "$@" &
    pid=$!
    ( sleep "$seconds"; kill -9 "$pid" 2>/dev/null ) >/dev/null 2>&1 &
    watcher=$!

    wait "$pid" 2>/dev/null || status=$?
    kill -9 "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true

    return "$status"
}

require_command() {
    local name="$1" hint="$2"
    command -v "$name" >/dev/null 2>&1 || error "$name not found. $hint"
}

human_size() {
    local bytes="${1:-0}"
    printf '%s MB' "$(( bytes / 1048576 ))"
}

cpu_brand() { sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown; }
hw_model()  { sysctl -n hw.model 2>/dev/null || echo unknown; }

cpu_feature_list() {
    {
        sysctl -n machdep.cpu.features 2>/dev/null || true
        printf ' '
        sysctl -n machdep.cpu.leaf7_features 2>/dev/null || true
    } | tr '[:lower:]' '[:upper:]'
}

cpu_has_feature() {
    local feature="$1"
    cpu_feature_list | tr ' ' '\n' | grep -qxF "$feature"
}

# ------------------------------------------------- binary health probing -----

# 0 = runs, 132 = SIGILL, anything else = some other failure.
probe_status() {
    local binary="$1" status=0

    [ -x "$binary" ] || return 127
    run_with_timeout "$PROBE_TIMEOUT" "$binary" --version </dev/null >/dev/null 2>&1 || status=$?
    return "$status"
}

describe_status() {
    case "$1" in
        0) printf 'runs' ;;
        "$SIGILL_STATUS") printf 'SIGILL (Illegal instruction: 4)' ;;
        127) printf 'not executable' ;;
        137) printf 'timed out' ;;
        *) printf 'failed (exit %s)' "$1" ;;
    esac
}

binary_runs() {
    local status=0
    probe_status "$1" || status=$?
    [ "$status" -eq 0 ]
}

binary_version() {
    run_with_timeout "$PROBE_TIMEOUT" "$1" --version </dev/null 2>/dev/null |
        awk 'NR==1{print $1}' || true
}

# Claude Desktop launches the agent with --await-initialize. A build that does
# not know the flag will start an interactive session instead and hang.
binary_supports_await_initialize() {
    local binary="$1" output

    output="$(run_with_timeout "$PROBE_TIMEOUT" "$binary" --await-initialize </dev/null 2>&1 || true)"
    printf '%s' "$output" | grep -q 'await-initialize' &&
        ! printf '%s' "$output" | grep -q 'unknown option'
}

binary_is_usable() {
    local binary="$1"

    binary_runs "$binary" && binary_supports_await_initialize "$binary"
}

# --------------------------------------------------- desktop app discovery ---

desktop_claude_code_version() {
    [ -d "$CLAUDE_CODE_DIR" ] || return 1
    ls -1 "$CLAUDE_CODE_DIR" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1
}

app_bundle_for()        { printf '%s/%s/claude.app\n' "$CLAUDE_CODE_DIR" "$1"; }
app_binary_for()        { printf '%s/%s/claude.app/Contents/MacOS/claude\n' "$CLAUDE_CODE_DIR" "$1"; }

# Replacing the executable inside claude.app invalidates the bundle signature.
# Reported rather than repaired on purpose: re-signing ad-hoc (codesign -f -s -)
# would swap Anthropic's Developer ID for an anonymous signature and can drop
# entitlements, which is a worse trade than a bundle Gatekeeper still admits.
signature_state() {
    local bundle="$1"
    [ -d "$bundle" ] || { printf 'no bundle'; return; }
    command -v codesign >/dev/null 2>&1 || { printf 'unknown (codesign unavailable)'; return; }
    if codesign --verify --deep --strict "$bundle" >/dev/null 2>&1; then
        printf 'valid'
    elif command -v spctl >/dev/null 2>&1 && spctl -a -t exec "$bundle" >/dev/null 2>&1; then
        printf 'invalidated by the patch (Gatekeeper still accepts it)'
    else
        printf 'invalidated by the patch (Gatekeeper REJECTS it)'
    fi
}
standalone_binary_for() { printf '%s/%s/claude\n' "$CLAUDE_CODE_DIR" "$1"; }
verified_marker_for()   { printf '%s/%s/.verified\n' "$CLAUDE_CODE_DIR" "$1"; }

# The pristine binary, whether it is still in place or already backed up.
pristine_binary_for() {
    local version="$1" candidate

    for candidate in \
        "$(app_binary_for "$version").bun.bak" \
        "$(standalone_binary_for "$version").bun.bak" \
        "$(app_binary_for "$version")" \
        "$(standalone_binary_for "$version")"; do
        if [ -f "$candidate" ] && ! is_our_binary "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

is_our_binary() {
    local path="$1" size

    [ -f "$path" ] || return 1

    if [ -f "$OVERRIDE_BINARY" ]; then
        local here there
        here="$(stat -f '%d:%i' "$path" 2>/dev/null || true)"
        there="$(stat -f '%d:%i' "$OVERRIDE_BINARY" 2>/dev/null || true)"
        if [ -n "$here" ] && [ "$here" = "$there" ]; then
            return 0
        fi
        if cmp -s "$path" "$OVERRIDE_BINARY"; then
            return 0
        fi
    fi

    # Only the small Mach-O launcher carries a marker string; skip the scan on
    # multi-hundred-megabyte native binaries.
    size="$(stat -f '%z' "$path" 2>/dev/null || echo 0)"
    if [ "$size" -lt 5242880 ]; then
        strings "$path" 2>/dev/null | grep -q "$WRAPPER_MARKER" && return 0
    fi

    return 1
}

# ------------------------------------------------- npm registry retrieval ----

platform_package() {
    case "$(uname -m)" in
        x86_64) printf '%s-darwin-x64\n' "$WRAPPER_PKG" ;;
        arm64)  printf '%s-darwin-arm64\n' "$WRAPPER_PKG" ;;
        *) return 1 ;;
    esac
}

tarball_url() {
    local pkg="$1" version="$2" base
    base="${pkg##*/}"
    printf '%s/%s/-/%s-%s.tgz\n' "$REGISTRY" "$pkg" "$base" "$version"
}

registry_latest_version() {
    curl -fsSL "$REGISTRY/$WRAPPER_PKG/latest" 2>/dev/null |
        sed -n 's/.*"version":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

# npm publishes dist.integrity as "sha512-<base64>" for every version. We are
# about to run this binary, so check it against what the registry claims.
registry_integrity() {
    local pkg="$1" version="$2"
    curl -fsSL "$REGISTRY/$pkg/$version" 2>/dev/null |
        sed -n 's/.*"integrity":[[:space:]]*"\(sha512-[^"]*\)".*/\1/p' | head -1
}

tarball_sha512_base64() {
    # LibreSSL ships with macOS, so this needs nothing installed.
    openssl dgst -sha512 -binary "$1" 2>/dev/null | openssl base64 -A 2>/dev/null
}

# 0 = matches, 1 = MISMATCH (caller must abort), 2 = could not check.
verify_tarball_integrity() {
    local tarball="$1" expected="$2" actual

    case "$expected" in
        sha512-?*) ;;
        *) return 2 ;;
    esac
    command -v openssl >/dev/null 2>&1 || return 2

    actual="$(tarball_sha512_base64 "$tarball")"
    [ -n "$actual" ] || return 2
    [ "$actual" = "${expected#sha512-}" ]
}

version_published() {
    local url http
    url="$(tarball_url "$(platform_package)" "$1")"
    http="$(curl -sSLI -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo 000)"
    [ "$http" = "200" ]
}

# Fetch just the single binary out of the platform tarball. Much lighter than a
# global `npm install`, and it never touches the user's own `claude` CLI.
download_native_binary() {
    local version="$1" destination="$2"
    local pkg url tarball

    pkg="$(platform_package)" || error "Unsupported CPU architecture: $(uname -m)"
    url="$(tarball_url "$pkg" "$version")"

    mkdir -p "$CACHE_DIR"
    tarball="$CACHE_DIR/${pkg##*/}-$version.tgz"

    local progress=(-sS)
    [ -t 1 ] && progress=(--progress-bar)

    log "Downloading $pkg@$version ..."
    if ! curl -fSL "${progress[@]}" "$url" -o "$tarball.part"; then
        rm -f "$tarball.part"
        return 1
    fi
    mv "$tarball.part" "$tarball"

    # Verify before unpacking: this binary is about to be executed and installed
    # as the agent Claude Desktop runs. A tampered tarball must not get that far.
    local expected integrity_status=0
    expected="$(registry_integrity "$pkg" "$version")"
    verify_tarball_integrity "$tarball" "$expected" || integrity_status=$?
    case "$integrity_status" in
        0) log "Integrity OK (sha512 matches the registry)" ;;
        1)
            rm -f "$tarball"
            error "Integrity check FAILED for $pkg@$version. The download does not match the sha512 the registry published. Refusing to install it."
            ;;
        *)
            warn "Could not verify integrity of $pkg@$version (no sha512 from the registry, or openssl unavailable). Continuing."
            ;;
    esac

    if ! tar -xzOf "$tarball" package/claude > "$destination.part" 2>/dev/null; then
        rm -f "$destination.part" "$tarball"
        return 1
    fi

    rm -f "$tarball"
    chmod +x "$destination.part"
    mv "$destination.part" "$destination"
}

# Reuse an already-installed npm binary when one is present and healthy, so a
# re-patch after a Desktop update usually needs no download at all.
find_local_npm_binary() {
    local roots=() root candidate

    if command -v npm >/dev/null 2>&1; then
        root="$(npm root -g 2>/dev/null || true)"
        [ -n "$root" ] && roots+=("$root")
    fi
    roots+=("/usr/local/lib/node_modules" "/opt/homebrew/lib/node_modules")

    for root in "${roots[@]}"; do
        for candidate in \
            "$root/$WRAPPER_PKG/bin/claude.exe" \
            "$root/$WRAPPER_PKG/bin/claude"; do
            [ -f "$candidate" ] || continue
            printf '%s\n' "$candidate"
        done
    done
}

# ----------------------------------------------- Node.js fallback launcher ---

write_node_launcher() {
    local destination="$1" cli_js="$2" strip_new_flags="$3" node_bin="$4"
    local tmp_dir source_path node_literal cli_literal

    require_command clang "Install the Xcode Command Line Tools: xcode-select --install"

    tmp_dir="$(mktemp -d)"
    source_path="$tmp_dir/claude-avx-launcher.c"
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
static const char *WRAPPER_MARKER = "$WRAPPER_MARKER";
static const int STRIP_NEW_FLAGS = $strip_new_flags;

static int starts_with(const char *value, const char *prefix) {
    return strncmp(value, prefix, strlen(prefix)) == 0;
}

int main(int argc, char **argv) {
    if (access(NODE_BIN, X_OK) != 0) {
        fprintf(stderr, "Error: node not found. Expected node at %s\\n", NODE_BIN);
        return 127;
    }

    char **args = calloc((size_t)argc + 2, sizeof(char *));
    if (args == NULL) {
        fprintf(stderr, "Error: out of memory (%s)\\n", WRAPPER_MARKER);
        return 126;
    }

    int out = 0;
    args[out++] = (char *)NODE_BIN;
    args[out++] = (char *)CLI_JS;

    for (int i = 1; i < argc; i++) {
        char *arg = argv[i];

        /* An older JS CLI rejects flags newer Desktop builds always pass. */
        if (STRIP_NEW_FLAGS) {
            if (strcmp(arg, "--assistant") == 0 || starts_with(arg, "--assistant=")) {
                continue;
            }
            if (strcmp(arg, "--await-initialize") == 0 || starts_with(arg, "--await-initialize=")) {
                continue;
            }
            if (strcmp(arg, "--managed-settings") == 0) {
                if (i + 1 < argc) {
                    i++;
                }
                continue;
            }
            if (starts_with(arg, "--managed-settings=")) {
                continue;
            }
            /* --channels is valid in the pinned SDK and carries the Remote
               Control channel, so it is passed through deliberately. */
        }

        args[out++] = arg;
    }

    args[out] = NULL;
    execv(NODE_BIN, args);
    fprintf(stderr, "Error: failed to exec %s: %s\\n", NODE_BIN, strerror(errno));
    return errno == ENOENT ? 127 : 126;
}
EOF

    clang -arch "$(uname -m)" -mmacosx-version-min=10.13 -O2 -mno-avx -mno-avx2 \
        "$source_path" -o "$destination"
    rm -rf "$tmp_dir"
}

resolve_cli_js() {
    local root="$1" candidate

    for candidate in "$root/$AGENT_SDK_PKG/cli.js" "$root/$WRAPPER_PKG/cli.js"; do
        if [ -f "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

build_node_fallback() {
    local node_bin npm_root cli_js

    log ""
    log "Falling back to the Node.js launcher (no usable native build)."

    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
    require_command node "Install Node.js (nvm works well) and run this script again."
    require_command npm "Install npm together with Node.js."
    node_bin="$(command -v node)"

    log "Installing $AGENT_SDK_PKG@$LAST_KNOWN_CLI_SDK_VERSION ..."
    npm install -g "$AGENT_SDK_PKG@$LAST_KNOWN_CLI_SDK_VERSION"

    npm_root="$(npm root -g)"
    cli_js="$(resolve_cli_js "$npm_root" || true)"
    [ -n "$cli_js" ] || error "cli.js not found under $npm_root; the Node.js fallback is unavailable."

    mkdir -p "$FIX_DIR"
    write_node_launcher "$OVERRIDE_BINARY" "$cli_js" 1 "$node_bin"
    chmod +x "$OVERRIDE_BINARY"

    INSTALL_MODE="node-launcher"
    INSTALL_SOURCE="$cli_js"
    INSTALL_VERSION="$LAST_KNOWN_CLI_SDK_VERSION"
}

# ---------------------------------------------------------- install steps ----

# Hard-link where possible: the native build is ~200 MB and would otherwise be
# duplicated three times. A Desktop update replaces the file rather than writing
# into it, so the linked copies stay independent.
place_binary() {
    local destination="$1"

    rm -f "$destination"
    if ! ln "$OVERRIDE_BINARY" "$destination" 2>/dev/null; then
        cp "$OVERRIDE_BINARY" "$destination"
    fi
    chmod +x "$destination"
}

set_local_binary_env() {
    if ! command -v launchctl >/dev/null 2>&1; then
        warn "launchctl not found; export CLAUDE_CODE_LOCAL_BINARY=$OVERRIDE_BINARY yourself."
        return
    fi

    local user_id
    user_id="$(id -u)"
    if launchctl asuser "$user_id" launchctl setenv CLAUDE_CODE_LOCAL_BINARY "$OVERRIDE_BINARY" 2>/dev/null; then
        log "Set GUI launchd variable CLAUDE_CODE_LOCAL_BINARY"
    elif launchctl setenv CLAUDE_CODE_LOCAL_BINARY "$OVERRIDE_BINARY" 2>/dev/null; then
        log "Set launchd variable CLAUDE_CODE_LOCAL_BINARY"
    else
        warn "Could not set CLAUDE_CODE_LOCAL_BINARY through launchctl."
    fi
}

write_state() {
    mkdir -p "$FIX_DIR"
    cat > "$STATE_FILE" <<EOF
desktop_version=$DESKTOP_VERSION
install_mode=$INSTALL_MODE
install_version=$INSTALL_VERSION
install_source=$INSTALL_SOURCE
patched_at=$(date '+%Y-%m-%dT%H:%M:%S%z')
EOF
}

read_state_value() {
    local key="$1"
    [ -f "$STATE_FILE" ] || return 1
    sed -n "s/^$key=//p" "$STATE_FILE" | head -1
}

# --------------------------------------------------------------- warnings ----

# A crashing `claude` earlier on PATH than a working one is a common source of
# confusion, because the SIGILL then comes from the CLI, not from Desktop.
report_path_conflicts() {
    local first
    first="$(command -v claude 2>/dev/null || true)"
    [ -n "$first" ] || return 0

    local status=0
    probe_status "$first" || status=$?

    if [ "$status" -eq "$SIGILL_STATUS" ]; then
        warn "the 'claude' CLI first on your PATH also faults with SIGILL:"
        warn "  $first"
        warn "  Reinstall it from npm (a current build no longer needs AVX2):"
        warn "    npm install -g $WRAPPER_PKG@latest"
    fi
}

# ------------------------------------------------------------------ modes ----

do_check() {
    local needs_patch="false"

    log "Claude Desktop AVX fix - diagnostics"
    log ""
    log "Machine"
    log "  Model:        $(hw_model)"
    log "  CPU:          $(cpu_brand)"
    log "  AVX:          $(cpu_has_feature AVX1.0 && echo yes || echo no)"
    log "  AVX2:         $(cpu_has_feature AVX2 && echo yes || echo no)"
    log ""

    DESKTOP_VERSION="$(desktop_claude_code_version || true)"
    if [ -z "$DESKTOP_VERSION" ]; then
        log "Claude Desktop"
        log "  No Claude Code bundle found under:"
        log "    $CLAUDE_CODE_DIR"
        log "  Install Claude Desktop and launch it once."
        return 1
    fi

    local app_binary pristine pristine_status=0 patched="no"
    app_binary="$(app_binary_for "$DESKTOP_VERSION")"
    is_our_binary "$app_binary" && patched="yes"

    log "Claude Desktop"
    log "  Claude Code:  $DESKTOP_VERSION"
    log "  Binary:       $app_binary"
    log "  Patched:      $patched"
    log "  Signature:    $(signature_state "$(app_bundle_for "$DESKTOP_VERSION")")"

    pristine="$(pristine_binary_for "$DESKTOP_VERSION" || true)"
    if [ -n "$pristine" ]; then
        probe_status "$pristine" || pristine_status=$?
        log "  Bundled:      $(describe_status "$pristine_status")"
    else
        log "  Bundled:      not found"
    fi
    log ""

    log "Fix state"
    if [ -f "$OVERRIDE_BINARY" ]; then
        local override_status=0
        probe_status "$OVERRIDE_BINARY" || override_status=$?
        log "  Override:     $OVERRIDE_BINARY"
        log "  Size:         $(human_size "$(stat -f '%z' "$OVERRIDE_BINARY")")"
        log "  Health:       $(describe_status "$override_status")"
        log "  Reports:      $(binary_version "$OVERRIDE_BINARY")"
        log "  Mode:         $(read_state_value install_mode || echo unknown)"
    else
        log "  Override:     not installed"
    fi
    local launchd_var
    launchd_var="$(launchctl getenv CLAUDE_CODE_LOCAL_BINARY 2>/dev/null || true)"
    log "  launchd var:  ${launchd_var:-(unset)}"
    log ""

    log "Verdict"
    if [ "$pristine_status" -eq "$SIGILL_STATUS" ]; then
        log "  This machine IS affected: the bundled build faults with SIGILL."
        if [ "$patched" = "yes" ] && [ -f "$OVERRIDE_BINARY" ] && binary_runs "$OVERRIDE_BINARY"; then
            log "  The fix is installed and working. Nothing to do."
        else
            log "  Run ./$SCRIPT_NAME to install the fix."
            needs_patch="true"
        fi
    elif [ -n "$pristine" ] && [ "$pristine_status" -eq 0 ]; then
        log "  This machine is NOT affected: the bundled build runs fine."
        if [ "$patched" = "yes" ] || [ -f "$OVERRIDE_BINARY" ]; then
            # Do not assume the override is older than the bundle: the fix may
            # well have pulled a newer build than the one Desktop ships.
            local override_version="" newest
            [ -f "$OVERRIDE_BINARY" ] && override_version="$(binary_version "$OVERRIDE_BINARY")"
            if [ -z "$override_version" ] || [ "$override_version" = "$DESKTOP_VERSION" ]; then
                log "  The fix is still installed and pins the same build as the bundle."
            else
                newest="$(printf '%s\n%s\n' "$override_version" "$DESKTOP_VERSION" | sort -V | tail -1)"
                if [ "$newest" = "$DESKTOP_VERSION" ]; then
                    log "  The fix is still installed and pins an older build ($override_version, bundle has $DESKTOP_VERSION)."
                else
                    log "  The fix is still installed and pins a newer build ($override_version, bundle has $DESKTOP_VERSION)."
                fi
            fi
            log "  Run ./$SCRIPT_NAME --restore to hand Claude Desktop back its own binary."
        fi
    else
        log "  Could not classify the bundled build: $(describe_status "$pristine_status")"
        log "  Run ./$SCRIPT_NAME --force to patch anyway."
    fi

    report_path_conflicts

    [ "$needs_patch" = "true" ] && return 2
    return 0
}

do_restore() {
    DESKTOP_VERSION="$(desktop_claude_code_version || true)"
    local restored=0 version

    for version in $(ls -1 "$CLAUDE_CODE_DIR" 2>/dev/null | sort -V); do
        local target
        for target in "$(app_binary_for "$version")" "$(standalone_binary_for "$version")"; do
            if [ -f "$target.bun.bak" ]; then
                rm -f "$target"
                mv "$target.bun.bak" "$target"
                chmod +x "$target"
                log "Restored: $target"
                restored=$((restored + 1))
            fi
        done
    done

    if command -v launchctl >/dev/null 2>&1; then
        launchctl asuser "$(id -u)" launchctl unsetenv CLAUDE_CODE_LOCAL_BINARY 2>/dev/null ||
            launchctl unsetenv CLAUDE_CODE_LOCAL_BINARY 2>/dev/null || true
        log "Unset launchd variable CLAUDE_CODE_LOCAL_BINARY"
    fi

    rm -f "$OVERRIDE_BINARY" "$STATE_FILE"
    rm -rf "$CACHE_DIR"
    log "Removed override binary and cache"

    if [ "$restored" -eq 0 ]; then
        log ""
        log "No pristine backup was found, so Claude Desktop will re-download its"
        log "own Claude Code bundle on the next launch."
    fi

    log ""
    log "Done. Restart Claude Desktop, and re-run the auto-repatch uninstall if"
    log "you installed it: ./install-auto-repatch.sh --uninstall"
}

acquire_native_binary() {
    local candidate version

    mkdir -p "$FIX_DIR"

    # 1. An npm build already on this machine.
    while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        log "Testing local npm build: $candidate"
        if binary_is_usable "$candidate"; then
            version="$(binary_version "$candidate")"
            log "  usable ($version)"
            cp "$candidate" "$OVERRIDE_BINARY.part"
            chmod +x "$OVERRIDE_BINARY.part"
            mv "$OVERRIDE_BINARY.part" "$OVERRIDE_BINARY"
            INSTALL_MODE="native-npm"
            INSTALL_VERSION="$version"
            INSTALL_SOURCE="$candidate"
            return 0
        fi
        log "  unusable, skipping"
    done < <(find_local_npm_binary)

    # 2. The published build matching the version Desktop wants, then the newest.
    require_command curl "curl is required to download a working build."
    require_command tar "tar is required to unpack the downloaded build."

    local wanted=()
    if [ -n "$PINNED_VERSION" ]; then
        wanted=("$PINNED_VERSION")
    else
        wanted=("$DESKTOP_VERSION")
        local latest
        latest="$(registry_latest_version || true)"
        if [ -n "$latest" ] && [ "$latest" != "$DESKTOP_VERSION" ]; then
            wanted+=("$latest")
        fi
    fi

    for version in "${wanted[@]}"; do
        if ! version_published "$version"; then
            log "$WRAPPER_PKG@$version is not published for this platform, skipping"
            continue
        fi
        if ! download_native_binary "$version" "$OVERRIDE_BINARY"; then
            warn "download of $WRAPPER_PKG@$version failed"
            continue
        fi
        if binary_is_usable "$OVERRIDE_BINARY"; then
            log "Installed native build $version"
            INSTALL_MODE="native-npm"
            INSTALL_VERSION="$version"
            INSTALL_SOURCE="$(tarball_url "$(platform_package)" "$version")"
            return 0
        fi
        warn "$WRAPPER_PKG@$version is not usable on this CPU either"
        rm -f "$OVERRIDE_BINARY"
    done

    return 1
}

do_patch() {
    DESKTOP_VERSION="$(desktop_claude_code_version || true)"
    [ -n "$DESKTOP_VERSION" ] ||
        error "No Claude Code bundle under $CLAUDE_CODE_DIR. Install Claude Desktop and launch it once."

    log "Claude Desktop Claude Code version: $DESKTOP_VERSION"
    log "CPU: $(cpu_brand)"
    log "AVX: $(cpu_has_feature AVX1.0 && echo yes || echo no)   AVX2: $(cpu_has_feature AVX2 && echo yes || echo no)"
    log ""

    local pristine pristine_status=0
    pristine="$(pristine_binary_for "$DESKTOP_VERSION" || true)"
    if [ -n "$pristine" ]; then
        log "Probing the bundled build ..."
        probe_status "$pristine" || pristine_status=$?
        log "  $(describe_status "$pristine_status")"
    else
        warn "no pristine bundled build found to probe"
        pristine_status=-1
    fi

    if [ "$pristine_status" -eq 0 ] && [ "$FORCE" != "true" ]; then
        log ""
        log "The bundled build runs on this CPU, so no patch is needed."
        if [ -f "$OVERRIDE_BINARY" ]; then
            log "An older override is still installed; ./$SCRIPT_NAME --restore removes it."
        fi
        log "Use --force to patch anyway."
        return 0
    fi

    log ""
    if ! acquire_native_binary; then
        build_node_fallback
    fi

    log ""
    place_binary_everywhere
    set_local_binary_env
    write_state
    print_summary
}

place_binary_everywhere() {
    local target

    chmod +x "$OVERRIDE_BINARY"
    log "Override binary: $OVERRIDE_BINARY"

    for target in "$(app_binary_for "$DESKTOP_VERSION")" "$(standalone_binary_for "$DESKTOP_VERSION")"; do
        if [ ! -e "$target" ] && [ ! -L "$target" ]; then
            continue
        fi

        if ! is_our_binary "$target" && [ ! -e "$target.bun.bak" ]; then
            mv "$target" "$target.bun.bak"
            log "Backed up: $target.bun.bak"
        fi

        place_binary "$target"
        log "Patched:   $target"
    done

    local marker
    marker="$(verified_marker_for "$DESKTOP_VERSION")"
    [ -e "$marker" ] || : > "$marker"
}

print_summary() {
    local status=0
    probe_status "$OVERRIDE_BINARY" || status=$?

    log ""
    log "Done."
    log "  Desktop version:  $DESKTOP_VERSION"
    log "  Mode:             $INSTALL_MODE"
    log "  Installed build:  $INSTALL_VERSION"
    log "  Source:           $INSTALL_SOURCE"
    log "  Verification:     $(describe_status "$status")"
    log ""
    if [ "$status" -ne 0 ]; then
        error "the installed binary does not run; nothing was fixed."
    fi
    log "Restart Claude Desktop to apply."
}

# ------------------------------------------------------------------- main -----

while [ $# -gt 0 ]; do
    case "$1" in
        --check) MODE="check" ;;
        --restore) MODE="restore" ;;
        --force) FORCE="true" ;;
        --pin)
            shift
            [ $# -gt 0 ] || error "--pin needs a version, e.g. --pin 2.1.266"
            PINNED_VERSION="$1"
            ;;
        --pin=*) PINNED_VERSION="${1#--pin=}" ;;
        -h|--help) usage; exit 0 ;;
        *) error "unknown option: $1 (try --help)" ;;
    esac
    shift
done

[ "$(uname -s)" = "Darwin" ] || error "This script is for macOS."

INSTALL_MODE="unknown"
INSTALL_VERSION="unknown"
INSTALL_SOURCE="unknown"
DESKTOP_VERSION=""

case "$MODE" in
    check) do_check ;;
    restore) do_restore ;;
    patch) do_patch ;;
esac
