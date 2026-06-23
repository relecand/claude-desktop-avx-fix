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

- [nvm](https://github.com/nvm-sh/nvm) with a working Node.js installation
- Xcode Command Line Tools (`clang`) to build the tiny launcher
- The Claude desktop app installed

## Usage

Use the `codex-fix-claude-sdk-cli-resolution` branch from this fork until the fixes are merged upstream:

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

Re-run the script after Claude Desktop updates:

```bash
./update-claude-desktop.sh
```

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

## Affected hardware

Any Intel Mac with a CPU older than Haswell (4th gen, 2013), including:
- Mac Pro 5,1 (2010/2012) - Westmere Xeon
- Mac Pro 4,1 (2009) - Nehalem Xeon
- Older iMacs, MacBooks, Mac Minis with Sandy Bridge or Ivy Bridge CPUs
