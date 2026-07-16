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

Detect arch on macOS/Linux with `uname -m` (`x86_64` -> amd64,
`arm64`/`aarch64` -> arm64).

## Quick install (macOS / Linux)

```sh
curl https://clor.com/install.sh | bash
```

Detects your OS/arch, downloads the matching binary into
`~/.local/bin/clor`, verifies its SHA-256 against the published
sidecar, adds `~/.local/bin` to `PATH` if missing, and runs `clor`.
It also schedules `clor install` every six hours using a systemd timer on
Linux or a launchd agent on macOS. Each run refreshes normal daemon and plugin
setup, but the installer skips the binary download when `clor version`
already matches the requested release. A failed run is attempted again at the
next scheduled time.

On Linux, a root/system timer runs continuously. A user timer runs while its
user manager is available; enable lingering if it must keep running while the
user is logged out. The timer uses `Persistent=true`, so a missed update runs
when the user manager starts again. On macOS, the launchd agent runs at login
and then every six hours while the user remains logged in.

To install without the six-hour updater, put the environment variable on
the `bash` side of the pipe so the installer receives it:

```sh
curl https://clor.com/install.sh | CLOR_AUTOUPDATE="false" bash
```

Running that command also stops and removes an updater installed by an
earlier run. Re-running the plain quick-install command enables it again.

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

## Sign in

```sh
clor account login
```

Prints a one-time approval URL. Open it, approve in the browser, and
the API key is saved automatically. Run `clor account login --help`
for `--wait` and other options.

## Upgrading

Automatic installs check every six hours. You can also re-run
`curl https://clor.com/install.sh | bash` or re-run the manual install
command for your platform. The new binary replaces the active version
atomically.

A normal install skips downloading the binary when the installed version
already matches `LATEST_VERSION` (or an explicit `CLOR_VERSION`). Use
`clor install --force` to reinstall the same version. When invoking the
shell installer directly, the equivalent is:

```sh
curl https://clor.com/install.sh | CLOR_INSTALL_FORCE="true" bash
```

To pin a release, set `CLOR_VERSION`. A pin does not install or retain the
six-hour updater unless you explicitly opt back in:

```sh
# Pin this release and disable automatic updates.
curl https://clor.com/install.sh | CLOR_VERSION="v1.7.1" bash

# Install this release now, then track future stable releases every six hours.
curl https://clor.com/install.sh | CLOR_VERSION="v1.7.1" CLOR_AUTOUPDATE="true" bash
```

## Uninstalling

Disable the updater before uninstalling. Otherwise a scheduled full
install could restore daemon or plugin components after they are removed.

```sh
# macOS / Linux
CLOR_AUTOUPDATE="false" clor install
clor uninstall
rm ~/.local/bin/clor
rm -rf ~/.local/share/clor
rm -rf ~/.clor
```
