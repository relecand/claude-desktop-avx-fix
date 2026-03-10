# claude-desktop-avx-fix

Fixes the Claude desktop app on older Intel Macs that lack AVX2 support (pre-Haswell CPUs, circa 2013).

## The Problem

The Claude desktop app bundles a native binary (built with Bun) that requires AVX2 CPU instructions. On older Intel Macs (e.g. Mac Pro 5,1 with Xeon X5675), this binary crashes immediately with:

```
Illegal instruction: 4
```

The Electron UI opens fine, but the app is unresponsive because its backend process dies on launch.

## The Fix

This script replaces the native Bun binary with a wrapper that runs the npm-distributed version of `@anthropic-ai/claude-code` via Node.js, which has no AVX2 requirement.

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

1. Updates `@anthropic-ai/claude-code` npm package to the latest version
2. Finds the latest version directory the desktop app created
3. Backs up the native Bun binary (if present)
4. Replaces it with a shell wrapper that invokes the Node.js version
5. Restart the Claude desktop app to apply

## Affected hardware

Any Intel Mac with a CPU older than Haswell (4th gen, 2013), including:
- Mac Pro 5,1 (2010/2012) - Westmere Xeon
- Mac Pro 4,1 (2009) - Nehalem Xeon
- Older iMacs, MacBooks, Mac Minis with Sandy Bridge or Ivy Bridge CPUs
