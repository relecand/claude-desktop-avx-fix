# claude-desktop-avx-fix

Gets Claude Desktop working on Intel Macs whose CPU has no AVX2 (anything older
than Haswell, so roughly pre-2013), where the bundled Claude Code agent dies
instantly with:

```
Illegal instruction: 4
```

The Electron window opens normally, but the agent process behind it is already
dead, so the app never answers anything.

> **Run `./update-claude-desktop.sh --check` first.** Recent Claude Code builds
> are compiled for a lower CPU baseline and no longer need AVX2, so many people
> who hit this in the past are no longer affected. The check tells you in a few
> seconds whether you need anything at all, and changes nothing.

## The bug

Claude Desktop downloads its own copy of the Claude Code agent into
`~/Library/Application Support/Claude/claude-code/<version>/`. That copy is a
single ~200 MB Bun-compiled Mach-O executable.

Some builds were compiled with AVX2 enabled. On a pre-Haswell CPU the process
dies with `SIGILL` / `EXC_BAD_INSTRUCTION` while dyld is still running static
initialisers, i.e. before `main()`, so there is no error message anywhere in the
UI — just an app that never responds:

```
Exception Type:  EXC_BAD_INSTRUCTION (SIGILL)
Termination:     Namespace SIGNAL, Code 4, Illegal instruction: 4
Thread 0 Crashed:
  0  claude.exe                      0x...
  ...
  3  dyld  invocation function for block in dyld4::Loader::findAndRunAllInitializers(...)
```

Crash reports land in `~/Library/Logs/DiagnosticReports/claude.exe-*.ips`.

### Measured on a MacBookPro9,2 (Core i5-3210M, Ivy Bridge — AVX1, no AVX2)

| Build | `claude --version` |
| --- | --- |
| `@anthropic-ai/claude-code@2.1.197` | **SIGILL, exit 132** |
| `@anthropic-ai/claude-code@2.1.266` | runs |
| `@anthropic-ai/claude-code@2.1.269` | runs |
| Claude Desktop's bundled 2.1.266 | runs |

So the AVX2 requirement was dropped somewhere between those versions. If your
Claude Desktop happens to ship an affected build, this script swaps in one that
works; if it ships a healthy build, the script tells you so and exits without
touching anything.

## The fix

`update-claude-desktop.sh` does, in order:

1. Probes the binary Claude Desktop downloaded. If it runs, you are not
   affected and nothing is changed.
2. Otherwise it gets a working native build of the *same* Claude Code version
   from npm, by pulling just the one executable out of the
   `@anthropic-ai/claude-code-darwin-x64` tarball. It never runs
   `npm install -g`, so your own `claude` CLI is left exactly as it is.
3. If that build faults too, it tries the newest published build.
4. As a last resort — for CPUs without even AVX1, where no native build can run
   — it compiles a small Mach-O launcher that runs the JavaScript CLI
   (`cli.js`) under Node.js.

Downloads are checked against the `sha512` the registry publishes in
`dist.integrity` before the tarball is unpacked; a mismatch aborts instead of
installing. The check uses the `openssl` that ships with macOS, so it needs
nothing extra. If the registry serves no hash, the run warns and continues.

Whatever it picks, it is verified by actually running it before anything is
declared fixed. The result is installed in three places:

- `~/Library/Application Support/Claude/claude-code-avx-fix/claude` — a stable
  path that survives Desktop updates
- `CLAUDE_CODE_LOCAL_BINARY`, set through `launchctl`, so Claude Desktop uses
  that path
- over the downloaded binary itself, as a fallback, with the original kept as
  `claude.bun.bak`

The copies are hard-linked, so the ~200 MB binary is stored once.

### Code signature

Replacing the executable inside `claude.app` invalidates the bundle's
signature, so `codesign --verify` and `spctl` both reject the bundle
afterwards:

```
claude.app: code has no resources but signature indicates they must be present
```

The binary that goes in is itself properly signed — `Developer ID Application:
Anthropic PBC (Q6L2SF6YDW)`, chaining to the Apple Root CA — so this is not
unsigned code; it is an authentic binary inside a wrapper whose signature no
longer closes. Claude Desktop launches the agent as a child process rather than
through LaunchServices, so Gatekeeper does not gate it in practice.

The script reports this in `--check` rather than repairing it. Re-signing
ad-hoc (`codesign -f -s -`) would replace Anthropic's Developer ID with an
anonymous signature and can drop entitlements — a worse trade than a bundle
that Gatekeeper never inspects. `--restore` puts the signed original back.

## Usage

```bash
git clone https://github.com/relecand/claude-desktop-avx-fix.git
cd claude-desktop-avx-fix
chmod +x update-claude-desktop.sh install-auto-repatch.sh

./update-claude-desktop.sh --check     # am I affected? changes nothing
./update-claude-desktop.sh             # patch, if needed
```

Then restart Claude Desktop.

| Command | What it does |
| --- | --- |
| `--check` | Diagnose only. Exits 0 when there is nothing to do, 2 when the fix is needed. |
| *(no flags)* | Patch, but only if the bundled binary actually faults. |
| `--force` | Patch even when the bundled binary looks healthy. |
| `--restore` | Put the original binary back, unset `CLAUDE_CODE_LOCAL_BINARY`, delete the override. |
| `--pin X.Y.Z` | Use a specific `@anthropic-ai/claude-code` version instead of auto-selecting. |
| `--help` | Usage. |

### After a Claude Desktop update

Claude Desktop downloads a fresh agent binary when it updates, which drops the
patch. Re-run `./update-claude-desktop.sh` — or install the helper below and
forget about it.

```bash
./install-auto-repatch.sh              # install
./install-auto-repatch.sh --uninstall  # remove
```

That installs a per-user LaunchAgent that watches Claude Desktop's `claude-code`
directory, runs `--check` after an update, and re-patches only when the new
binary is actually broken. It does not block Desktop updates and does not lock
any app-managed file. Logs:

```bash
tail -f ~/Library/Logs/claude-desktop-avx-fix.log
```

Keep this checkout in place — the LaunchAgent calls the script from here.

## Requirements

For the normal path, everything needed already ships with macOS:

- macOS on Intel (`x86_64`); Apple Silicon Macs are not affected by this bug
- Claude Desktop installed and launched at least once, so its Claude Code
  bundle exists
- `curl`, `tar`, `launchctl`

Only the two optional extras need installing:

- **Node.js and npm** — only for the Node.js fallback on CPUs without AVX1
- **Xcode Command Line Tools** (`clang`) — only to build that fallback's
  launcher: `xcode-select --install`

## Affected hardware

Any Intel Mac older than Haswell (4th gen, 2013) lacks AVX2:

- Mac Pro 4,1 (Early 2009) — Nehalem Xeon
- Mac Pro 5,1 (Mid 2010 / Mid 2012) — Westmere Xeon
- Mac Pro 6,1 (Late 2013) — Ivy Bridge Xeon E5 v2
- MacBook Pro 8,x (2011) — Sandy Bridge
- MacBook Pro 9,x (Mid 2012) — Ivy Bridge
- MacBook Pro 10,x (Retina 2012 / Early 2013) — Ivy Bridge
- MacBook Air 4,x (Mid 2011) — Sandy Bridge
- MacBook Air 5,x (Mid 2012) — Ivy Bridge
- iMac 12,x (Mid 2011) — Sandy Bridge
- iMac 13,x (Late 2012 / Early 2013) — Ivy Bridge
- Mac mini 5,x (Mid 2011) — Sandy Bridge
- Mac mini 6,x (Late 2012) — Ivy Bridge

Haswell and newer (MacBookPro11,x, MacBookAir6,x, iMac14,x, Macmini7,1 and up)
have AVX2 and should not need this.

Note that the npm `darwin-x64` build still requires **AVX1**. Core 2 Duo Macs
(iMac 10,x/11,x, Mac mini 4,1, pre-2011 MacBooks) have neither AVX nor AVX2, so
they land on the Node.js fallback — which needs Node.js and `clang`, and depends
on an older agent SDK that still ships `cli.js`.

## Check whether you are affected, by hand

```bash
sysctl -n machdep.cpu.leaf7_features | tr ' ' '\n' | grep -x AVX2 || echo "no AVX2"

D="$HOME/Library/Application Support/Claude/claude-code"
V=$(ls -1 "$D" | sort -V | tail -1)
"$D/$V/claude.app/Contents/MacOS/claude" --version; echo "exit=$?"   # 132 = SIGILL
```

A stale `claude` CLI can cause the same crash independently of Desktop. If
`claude --version` faults in your terminal, reinstall it:

```bash
npm install -g @anthropic-ai/claude-code@latest
```

## Credits

Originally by [relecand](https://github.com/relecand/claude-desktop-avx-fix),
which established the diagnosis and the Node.js launcher fallback.

Later additions: health probing of the bundled binary, the `--check` and
`--restore` modes, sourcing the replacement from the npm platform tarball so a
patch never touches your global npm install, `sha512` verification of that
download, stale-lock recovery in the auto-repatch watcher, and reporting the
bundle's code-signature state.
