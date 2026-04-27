# claude-desktop-avx-fix

Fixes the Claude desktop app on older Intel Macs that lack AVX2 support (pre-Haswell CPUs, circa 2013).

## The Problem

The Claude desktop app bundles a native binary (built with Bun) that requires AVX2 CPU instructions. On older Intel Macs (e.g. Mac Pro 5,1 with Xeon X5675), this binary crashes immediately with:

```
Illegal instruction: 4
```

The Electron UI opens fine, but the app is unresponsive because its backend process dies on launch.

## The Fix

This script replaces the native binary with a wrapper that runs the npm-distributed `cli.js` from the Claude agent SDK via Node.js, which avoids the AVX2-only native path on older Intel Macs.

Recent Claude releases no longer ship `cli.js` inside `@anthropic-ai/claude-code`, and newer `@anthropic-ai/claude-agent-sdk` builds removed it as well. The script now reads the SDK version bundled by your installed Claude Desktop app, tries the matching SDK build first, and falls back to the last known SDK version that still ships `cli.js` when needed. When that fallback is active, the generated wrapper also strips newer Desktop-only flags that the old JS CLI does not understand.

## Requirements

- [nvm](https://github.com/nvm-sh/nvm) with a working Node.js installation
- The Claude desktop app installed

## Usage

```bash
# First time
git clone https://github.com/$(gh api user -q .login)/claude-desktop-avx-fix.git
cd claude-desktop-avx-fix
chmod +x update-claude-desktop.sh
./update-claude-desktop.sh
```

Re-run the script after the desktop app updates:

```bash
./update-claude-desktop.sh
```

## What it does

1. Finds the latest version directory the desktop app created
2. Reads the bundled `@anthropic-ai/claude-agent-sdk` version from your local Claude Desktop app
3. Installs the matching SDK version via npm
4. Falls back to the last known JS-CLI SDK build if the matching version no longer ships `cli.js`
5. Backs up the native binary (if present)
6. Replaces it with a shell wrapper that invokes `node .../cli.js`
7. In fallback mode, strips newer Desktop-only flags such as `--managed-settings`, `--assistant`, and `--channels` before launching the old JS CLI
8. Restart the Claude desktop app to apply

## Affected hardware

Any Intel Mac with a CPU older than Haswell (4th gen, 2013), including:
- Mac Pro 5,1 (2010/2012) - Westmere Xeon
- Mac Pro 4,1 (2009) - Nehalem Xeon
- Older iMacs, MacBooks, Mac Minis with Sandy Bridge or Ivy Bridge CPUs
