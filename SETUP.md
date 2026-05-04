# Installing and authenticating the clor CLI

`clor` ships as a single static binary per platform. Install it under the
current user's home directory, no sudo or admin rights required.

You will also need a Clor API key. The user must create one at
[https://clor.com/apikeys](https://clor.com/apikeys). Ask them for it
after the binary is installed; do not invent or guess a key.

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
`arm64`/`aarch64` -> arm64). On macOS, Apple Silicon machines report
`arm64`.

## Quick install via npx (macOS / Linux)

If Node.js is available, the simplest option is the npm wrapper. It
downloads the right binary for your platform into `~/.local/bin/clor`,
adds that directory to `PATH`, and then runs the command you passed.

```sh
npx @clor/cli setup
```

This walks through authentication via `clor setup`. After the first run,
`clor` is on `PATH` and can be invoked directly. To pull the latest
release at any time, run `npx @clor/cli upgrade`.

Skip to [Authenticating](#authenticating) once `clor setup` completes.
The manual instructions below are for environments without Node.js.

## Install (macOS / Linux)

The convention is `~/.local/bin`, which most modern shells already include
on `PATH` (it is part of the XDG base-directory spec).

```sh
# Replace <ASSET> with the row from the table above.
mkdir -p ~/.local/bin
curl -fsSL -o ~/.local/bin/clor \
  https://github.com/clorhq/cli/releases/latest/download/<ASSET>
chmod +x ~/.local/bin/clor
```

If `clor: command not found` after install, `~/.local/bin` is not on
`PATH`. Add it (pick the line matching the user's shell):

```sh
# bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
# zsh (default on macOS)
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
# fish
fish_add_path ~/.local/bin
```

Then reopen the shell (or `source` the file).

## Install (Windows, PowerShell)

Install under `%LOCALAPPDATA%\Programs\clor` and prepend it to the user
`PATH`. No admin shell required.

```powershell
# Replace <ASSET> with the .exe row from the table above.
$dest = "$env:LOCALAPPDATA\Programs\clor"
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Invoke-WebRequest `
  -Uri https://github.com/clorhq/cli/releases/latest/download/<ASSET> `
  -OutFile "$dest\clor.exe"

# Add to user PATH if missing.
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notlike "*$dest*") {
  [Environment]::SetEnvironmentVariable("Path", "$dest;$userPath", "User")
}
```

Open a new PowerShell window so the updated `PATH` takes effect.

## Verifying the install

```sh
clor version
```

Prints the semver string the binary was built with (matches the GitHub
release tag, e.g. `v0.1.0`).

## Authenticating

Set the API key once. All Clor API keys start with the `clor_` prefix.

```sh
clor config set api.key clor_...
```

Or export `CLOR_API_KEY` in the environment instead of writing it to disk.
Config lives at `~/.clor/config.toml` (or `%USERPROFILE%\.clor\config.toml`
on Windows).

Confirm the CLI is authenticated:

```sh
clor account login
```

It prints the current auth state, the identity associated with the API
key, and (if not authenticated) the URL the user should visit to fix it.

For scripting:

```sh
# boolean check
clor account login --output json | jq .authenticated
# the signed-in email
clor account login --output json | jq --raw-output .user.email
```

If `authenticated` is `false`, follow the URL printed in the output,
update the key with `clor config set api.key clor_...`, and re-run
`clor account login`.

## Upgrading

If you installed via `npx`, pull the latest release with:

```sh
npx @clor/cli upgrade
```

For manual installs, re-run the same `curl` / `Invoke-WebRequest`
command from above. The new binary overwrites the old one in place.

## Uninstalling

Delete the binary and (optionally) the config directory:

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
