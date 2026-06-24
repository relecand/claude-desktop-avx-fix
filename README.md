# claude-desktop-avx-fix

Fixes the Claude desktop app on older Intel Macs that lack AVX2 support (pre-Haswell CPUs, circa 2013).

## The Problem

The Claude desktop app bundles a native binary (built with Bun) that requires AVX2 CPU instructions. On older Intel Macs (e.g. Mac Pro 5,1 with Xeon X5675), this binary crashes immediately with:

```
Illegal instruction: 4
```

The Electron UI opens fine, but the app is unresponsive because its backend process dies on launch.

## The Fix

This script installs a small Mach-O launcher that runs the npm-distributed `cli.js` from the Claude agent SDK via Node.js, which avoids the AVX2-only native path on older Intel Macs.

Recent Claude releases no longer ship `cli.js` inside `@anthropic-ai/claude-code`, and newer `@anthropic-ai/claude-agent-sdk` builds removed it as well. The script now reads the SDK version bundled by your installed Claude Desktop app, tries the matching SDK build first, and falls back to the last known SDK version that still ships `cli.js` when needed. When that fallback is active, the generated launcher also strips newer Desktop-only flags that the old JS CLI does not understand. The launcher embeds the absolute Node.js path found during patching so it can still launch from Claude Desktop's limited app environment. It is compiled as a Mach-O executable so Claude Desktop's binary cache check does not purge it as an invalid shell script.

## Requirements

- Claude Desktop installed and launched at least once, so it has created its local Claude Code bundle
- Node.js and npm available on your shell `PATH`; [nvm](https://github.com/nvm-sh/nvm) works well, but is not strictly required
- A user-writable global npm install location, because the script runs `npm install -g`
- Xcode Command Line Tools (`clang`) to build the tiny Mach-O launcher
- macOS `launchctl` and `plutil` for the optional auto-repatch helper; both are included with macOS

The scripts perform preflight checks for these requirements and fail early with a clear error message when something is missing or not writable.

### Installing requirements

Claude Desktop:

Download the macOS app from [claude.com/download](https://claude.com/download), move it to `/Applications`, sign in, and launch it once. This creates the local Claude Code bundle that the patch script modifies.

Xcode Command Line Tools:

```bash
xcode-select --install
clang --version
```

Node.js and npm:

Install Node.js with [nvm](https://github.com/nvm-sh/nvm#installing-and-updating), then open a new terminal and run:

```bash
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
nvm install --lts
nvm use --lts
node -v
npm -v
```

User-writable npm global prefix:

```bash
mkdir -p "$HOME/.local"
npm config set prefix "$HOME/.local"
export PATH="$HOME/.local/bin:$PATH"
```

Add the same `PATH` export to your shell profile (`~/.zshrc`, `~/.bashrc`, or `~/.bash_profile`) if `~/.local/bin` is not already on your `PATH`.

Auto-repatch helper:

No extra install is needed for `launchctl` or `plutil`; both are included with macOS.

## Usage

Use the `codex-fix-claude-sdk-cli-resolution` branch from this fork until the fixes are merged upstream:

> **Important:** Run `./update-claude-desktop.sh` again after every Claude Desktop update. Claude Desktop downloads a fresh Claude Code binary during updates, so the AVX-compatible launcher must be re-applied.

```bash
# First time
git clone --branch codex-fix-claude-sdk-cli-resolution https://github.com/relecand/claude-desktop-avx-fix.git
cd claude-desktop-avx-fix
chmod +x update-claude-desktop.sh
./update-claude-desktop.sh
```

If you already cloned the repository, switch to the fix branch and update it:

```bash
git fetch origin
git switch codex-fix-claude-sdk-cli-resolution
git pull --ff-only
./update-claude-desktop.sh
```

After each Claude Desktop update, run the patch again:

```bash
./update-claude-desktop.sh
```

## Automatic repatch after updates

Recommended: install the auto-repatch helper so you do not have to remember running the patch manually after each Claude Desktop update.

The helper installs a per-user macOS LaunchAgent. It runs after login and whenever Claude Desktop updates its local Claude Code bundle. It does not block Claude Desktop updates or lock any app-managed files; it simply re-applies `update-claude-desktop.sh` after the update lands.

```bash
chmod +x install-auto-repatch.sh
./install-auto-repatch.sh
```

The auto-repatcher writes logs to:

```bash
~/Library/Logs/claude-desktop-avx-fix.log
```

To remove the LaunchAgent:

```bash
./install-auto-repatch.sh --uninstall
```

Keep this repository checkout in place after installing the helper. The LaunchAgent calls `update-claude-desktop.sh` from this directory.

## What it does

1. Finds the latest version directory the desktop app created
2. Reads the bundled `@anthropic-ai/claude-agent-sdk` version from your local Claude Desktop app
3. Installs the matching SDK version via npm
4. Falls back to the last known JS-CLI SDK build if the matching version no longer ships `cli.js`
5. Compiles a small x86_64 Mach-O launcher that invokes Node.js and `cli.js`
6. Installs a stable local override launcher under Claude's Application Support directory
7. Sets `CLAUDE_CODE_LOCAL_BINARY` via `launchctl` so Claude Desktop can use that launcher
8. Backs up and patches the downloaded native binary as a fallback
9. Embeds the absolute Node.js path used to run `cli.js`, avoiding app-launch `PATH` issues
10. In fallback mode, strips newer Desktop-only flags such as `--managed-settings`, `--assistant`, and `--channels` before launching the old JS CLI
11. Restart the Claude desktop app to apply

The optional `install-auto-repatch.sh` helper installs a user LaunchAgent that watches Claude Desktop's `claude-code` directory and re-runs this patch after updates. It does not block Claude Desktop updates or lock any app-managed files.

## Affected hardware

Any Intel Mac with a CPU older than Haswell (4th gen, 2013) may be affected, because these CPUs do not support AVX2. Known affected model families include:

- Mac Pro 4,1 (Early 2009) - Nehalem Xeon
- Mac Pro 5,1 (Mid 2010/Mid 2012) - Westmere Xeon
- Mac Pro 6,1 (Late 2013) - Ivy Bridge Xeon E5 v2
- MacBook Pro 8,x (Early/Late 2011) - Sandy Bridge
- MacBook Pro 9,x (Mid 2012), including MacBookPro9,1 - Ivy Bridge
- MacBook Pro 10,x (Retina Mid 2012/Early 2013) - Ivy Bridge
- MacBook Air 4,x (Mid 2011) - Sandy Bridge
- MacBook Air 5,x (Mid 2012) - Ivy Bridge
- iMac 12,x (Mid 2011) - Sandy Bridge
- iMac 13,x (Late 2012/Early 2013) - Ivy Bridge
- Mac mini 5,x (Mid 2011) - Sandy Bridge
- Mac mini 6,x (Late 2012) - Ivy Bridge

Older Intel Macs, such as Core 2 Duo MacBooks/MacBook Pros/MacBook Airs, iMac 10,x/11,x, and Mac mini 4,1, also lack AVX2. They may need additional OS-level patching and are less likely to run current Claude Desktop successfully, but the underlying AVX2 issue is the same.

Haswell and newer Intel Macs usually support AVX2 and should not need this workaround. Examples that are normally outside the affected range include MacBookPro11,x and newer, MacBookAir6,x and newer, iMac14,x and newer, and Macmini7,1 and newer.
