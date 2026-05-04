# Installing the clor CLI

`clor` ships as a single static binary per platform. Install it under
the current user's home directory; no sudo or admin rights required.

## Pick the right asset

| OS      | Architecture            | Asset filename              |
| ------- | ----------------------- | --------------------------- |
| macOS   | Apple Silicon (M1+)     | `clor-darwin-arm64`         |
| macOS   | Intel                   | `clor-darwin-amd64`         |
| Linux   | x86_64                  | `clor-linux-amd64`          |
| Linux   | arm64 / aarch64         | `clor-linux-arm64`          |
| Windows | x86_64                  | `clor-windows-amd64.exe`    |
| Windows | arm64                   | `clor-windows-arm64.exe`    |

Detect arch on macOS/Linux with `uname -m` (`x86_64` -> amd64,
`arm64`/`aarch64` -> arm64).

## Quick install (macOS / Linux)

```sh
curl https://clor.com/install.sh | bash
```

Detects your OS/arch, downloads the matching binary into
`~/.local/bin/clor`, verifies its SHA-256 against the published
sidecar, adds `~/.local/bin` to `PATH` if missing, and runs `clor`.
Re-running overwrites in place, so it doubles as the upgrade path.

## Alternative: install via npx (macOS / Linux)

If Node.js is already on the box, the npm wrapper does the same job:

```sh
npx @clor/cli setup
```

Pull the latest release later with `npx @clor/cli upgrade`.

## Install (macOS / Linux, manual)

```sh
# Replace <ASSET> with the row from the table above.
mkdir -p ~/.local/bin
curl -fsSL -o ~/.local/bin/clor \
  https://github.com/clorhq/cli/releases/latest/download/<ASSET>
chmod +x ~/.local/bin/clor
```

If `clor: command not found` after install, add `~/.local/bin` to
`PATH` (`~/.bashrc`, `~/.zshrc`, or `fish_add_path ~/.local/bin`) and
reopen the shell.

## Install (Windows, PowerShell)

```powershell
# Replace <ASSET> with the .exe row from the table above.
$dest = "$env:LOCALAPPDATA\Programs\clor"
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Invoke-WebRequest `
  -Uri https://github.com/clorhq/cli/releases/latest/download/<ASSET> `
  -OutFile "$dest\clor.exe"

$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notlike "*$dest*") {
  [Environment]::SetEnvironmentVariable("Path", "$dest;$userPath", "User")
}
```

Open a new PowerShell window so the updated `PATH` takes effect.

## Sign in

```sh
clor account login
```

Prints a one-time approval URL. Open it, approve in the browser, and
the API key is saved automatically. Run `clor account login --help`
for `--wait` and other options.

## Upgrading

Re-run `curl https://clor.com/install.sh | bash`, run
`npx @clor/cli upgrade`, or re-run the manual `curl` /
`Invoke-WebRequest` command. The new binary overwrites the old one in
place.

## Uninstalling

```sh
# macOS / Linux
rm ~/.local/bin/clor
rm -rf ~/.clor
```

```powershell
# Windows
Remove-Item "$env:LOCALAPPDATA\Programs\clor\clor.exe"
Remove-Item -Recurse -Force "$env:USERPROFILE\.clor"
```
