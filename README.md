# Cline Desktop — rebuild the sidecar for pre-AVX2 CPUs (Windows x64)

A PowerShell script that rebuilds Cline Desktop's `code-sidecar.exe` with **Bun 1.4.x** so that it starts on Windows x64 CPUs that do not support AVX2.

## Status

As of **2026-09-26**:

| Item | State |
| --- | --- |
| Desktop **v0.0.37** (latest release, published 2026-09-26) | **Still affected** — ships a Bun 1.3.13 sidecar compiled for the standard `bun-windows-x64` target |
| Upstream issue [cline/cline#14066](https://github.com/cline/cline/issues/14066) | Open — community reports cover desktop v0.0.26 through v0.0.37 |
| Upstream PR [cline/cline#14082](https://github.com/cline/cline/pull/14082) ("use baseline Bun target for Windows x64 sidecar") | Open, not merged |
| npm CLI (`cline@3.0.65`, binary shipped as `@cline/cli-windows-x64`) | **Affected as well** — built with the same Bun 1.3.13 standard x64 target (`cli-publish.yml`, `apps/cli/script/build.ts` at tag `cli-v3.0.65`). This repository does not patch the CLI |
| This patch, verified against v0.0.37 | Works — sidecar rebuilt with Bun 1.4.2 starts and stays up |

The script itself needs no version-specific changes: it reads the installed app version, checks out the matching tag, and rebuilds. Until upstream ships baseline binaries, re-running it after each desktop update is what keeps Cline working on affected CPUs.

## Symptom

On affected machines Cline Desktop opens but behaves as if it were offline — the backend never becomes available and no models can be used. Windows records an Application Error 1000 for the sidecar:

```
Faulting application name: code-sidecar.exe
Exception code: 0xc0000005          (access violation, module ntdll.dll)
Faulting module offsets: 0x649e6 / 0x2fcaf
```

The desktop app's `hooks.jsonl` records `failed_external_process_exit`, and the sidecar process never opens an outbound TCP connection — it dies during startup, repeatedly.

## Root cause

The sidecar bundled with the desktop app is compiled with Bun 1.3.13 using the standard `bun-windows-x64` target. Per the Bun documentation, the x64 runtime target is built for Nehalem (SSE4.2) but distributes code paths selected at runtime that use AVX2/AVX-512. On a CPU without AVX2 the sidecar faults before it can serve the UI, which surfaces as "Cline cannot go online".

**Affected CPU class** — any Windows x64 CPU without AVX2, including CPUs that have AVX but not AVX2. Reports on #14066 cover, among others: Nehalem (Core i7 Q740), Westmere-EP (Xeon X5650), Ivy Bridge (Core i5-3470) and Whiskey Lake Pentium Gold 5405U. CPUs with AVX2 are unaffected.

Tracked upstream:

- **cline/cline#14066** — *Desktop backend + CLI crash-loop on pre-AVX CPUs — ship Windows x64 `-baseline` Bun binaries* (open)
- **cline/cline#14082** — *fix(desktop): use baseline Bun target for Windows x64 sidecar* (proposed fix, open, not merged)

## How this fix works

Rebuild the *same* sidecar source with **Bun 1.4.x** and replace the installed `code-sidecar.exe`. Bun 1.4.0+ builds target baseline CPU support by default (noted in the #14066 thread), so no extra compilation flags beyond the ones already used by the script are required. The resulting executable reports its own Bun version in `FileVersion` (e.g. `1.4.2`), starts cleanly on the affected CPU class, and the app UI works normally afterwards.

Evidence from the machine that motivated this fix, after replacing the binary:

- process image: `...\code-sidecar.exe`, FileVersion `1.4.2`, ~107 MB
- a listening port owned by the process, 6 established connections
- PID stable across launch cycles (no crash-restart loop)

The script never replaces anything blindly — it validates the freshly built artifact (version match + size sanity) and backs up the file it replaces.

## Requirements

- Windows 10 / 11 x64
- [Bun](https://bun.sh) **1.4.x** — `bun.exe` is used only as the compiler
- `git`
- A Cline Desktop installation you can modify (the script stops and restarts it)
- PowerShell 5.1+

## Usage

```powershell
# Defaults point at the author's layout (D:\Cline, D:\cline-build\cline,
# D:\cline-build\bun.exe) — pass your own paths:
powershell -ExecutionPolicy Bypass -File .\repatch-cline-sidecar.ps1 `
    -ClineDir        "C:\Path\To\Cline" `
    -RepoDir         "D:\cline-build\cline" `
    -BunExe          "D:\cline-build\bun.exe" `
    -ChineseLauncher "" `
    -PinnedDir       ""
```

| Parameter | Meaning |
| --- | --- |
| `-ClineDir` | Install directory that contains `cline-app.exe` (the installed `code-sidecar.exe` lives there too). |
| `-RepoDir` | A git clone of `cline/cline`. The script fetches and checks out the tag matching the installed app version (`desktop-v<version>`). |
| `-BunExe` | Path to a Bun 1.4.x `bun.exe`. |
| `-ChineseLauncher` | Optional launcher script used to start the app. If the path does not exist, `cline-app.exe` is started directly. |
| `-PinnedDir` | Optional. Writes a second copy of the patched sidecar outside the app directory (see *Surviving app updates*). |
| `-Tag` | Optional tag override, in case app versions and tags ever diverge. |

## What the script does

1. Reads `cline-app.exe` FileVersion → tag `desktop-v<version>`.
2. `git fetch --depth 1` + `git checkout -f <tag>` in `-RepoDir`.
3. `bun install`, then `bun run build:sdk`.
4. Compiles the sidecar (equivalent to):

   ```
   bun build ./sidecar/index.ts --compile --target=bun-windows-x64 \
     --no-compile-autoload-dotenv --no-compile-autoload-bunfig \
     --compile-exec-argv=--use-system-ca \
     --outfile apps/examples/desktop-app/src-tauri/bin/code-sidecar-x86_64-pc-windows-msvc.exe
   ```

   Guards: the artifact's `FileVersion` must equal `bun --version`, and it must be larger than 100 MB — otherwise the script aborts and leaves the installation untouched.
5. Stops `cline-app.exe` and `code-sidecar.exe` (plus a helper Node injector process, when one is registered), backs up the existing sidecar to `code-sidecar.exe.bak-<version>`, then copies the rebuilt binary into place. With `-PinnedDir` set, the same binary is also copied there.
6. Restarts the app and verifies: the sidecar owns a listening port, its PID is unchanged after another 30 seconds, and `cline-app.exe` is alive.

## Verifying manually

```powershell
(Get-Item "D:\Cline\code-sidecar.exe").VersionInfo.FileVersion   # e.g. 1.4.2 — equals your bun --version
(Get-Item "D:\Cline\code-sidecar.exe").Length                    # > 100 MB
Get-Process code-sidecar | Select-Object Id, Path
Get-NetTCPConnection -State Listen -OwningProcess (Get-Process code-sidecar).Id
```

Then open Cline and confirm the backend responds (models list loads, requests complete).

## Surviving app updates

Installing a new desktop version overwrites `code-sidecar.exe`, so the patched binary has to be re-applied — re-run the script; it picks the matching tag automatically. (The desktop updater only runs when a user triggers it from the UI.)

Optional hardening: the desktop app resolves its backend binary from the `CLINE_CODE_SIDECAR_BIN` environment variable before falling back to the bundled path. Keeping a patched copy outside the install directory and pointing that variable at it means an update no longer breaks startup immediately — re-running the script is still recommended, since a new app version may ship a different sidecar.

## Limitations

- **Windows x64 only.** The crash is specific to the x64 Bun runtime; on CPUs with AVX2 the official sidecar works and this patch is unnecessary.
- **The npm CLI is out of scope.** `cline@3.0.65` is compiled the same way (Bun 1.3.13, standard x64 target) and fails the same way on affected CPUs; patching it would mean rebuilding its binary from source and re-applying after every CLI update.
- The script stops Cline while patching and needs network access for `git fetch` / `bun install`.
- The first run initializes a source checkout and build dependencies; later runs reuse them.
- The exact `ntdll` fault offsets vary by Windows build — they are diagnostic evidence only, nothing the script depends on.

## Disclaimer

Community-maintained and unofficial. Not affiliated with, endorsed by, or supported by Cline or its maintainers. This repository contains **no** Cline binaries, no bundled runtimes, and no third-party assets — only a PowerShell script under the MIT license. "Cline" and related marks belong to their respective owners. Use at your own risk; the script backs up the file it replaces.

## References

- [cline/cline#14066](https://github.com/cline/cline/issues/14066) — Desktop backend + CLI crash-loop on pre-AVX CPUs
- [cline/cline#14082](https://github.com/cline/cline/pull/14082) — fix(desktop): use baseline Bun target for Windows x64 sidecar
- Bun documentation — `bun build --compile` and cross-compilation targets

## License

MIT — see [LICENSE](LICENSE).