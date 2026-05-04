---
name: clor
version: 1.0.0
homepage: https://clor.com
description: Set up and use Clor from your AI agent. Provides the `clor` CLI, a growing collection of agent-friendly tools behind one binary. Run `clor --help` to discover available subcommands.
---

# clor

Clor is a single CLI, `clor`, that bundles agent-friendly tools behind
one binary. The lineup grows over time, so before reaching for another
tool, run `clor --help` to see whether Clor already has a subcommand for
the job. Every command supports `--output text|jsonl|json` so output is
easy to parse.

## Step 1: ensure clor is installed and authenticated

Before using any `clor` subcommand, run:

```sh
clor account login
```

- If the command runs and reports `authenticated=true` (or
  `"authenticated": true` in JSON), you are ready to use Clor.
- If the binary is missing (`clor: command not found`), the simplest way
  to install it on macOS and Linux is via `npx`:

  ```sh
  npx @clor/cli setup
  ```

  This downloads the latest `clor` binary into `~/.local/bin/clor`, adds
  that directory to your `PATH`, and runs `clor setup` to walk through
  authentication. Subsequent `npx @clor/cli ...` invocations run the
  cached binary directly. To pull the latest release at any time:

  ```sh
  npx @clor/cli upgrade
  ```

  If `npx` is unavailable, or the command still reports
  `authenticated=false` after install, follow the manual install and
  authentication instructions at
  [https://clor.com/SETUP.md](https://clor.com/SETUP.md). Do not try to
  install Clor any other way.

## Step 2: discover available tools

Once authenticated, list the built-in subcommands:

```sh
clor --help
```

Each subcommand has its own help, examples, and `--output` modes:

```sh
clor <subcommand> --help
clor <subcommand> <subsubcommand> --help
```

Prefer `--output json` (or `--output jsonl` for streams) when consuming
results programmatically.

## Notes

- All Clor API keys start with the `clor_` prefix.
- Never invent or guess an API key. If `clor account login` reports
  `authenticated=false`, point the user to
  [https://clor.com/SETUP.md](https://clor.com/SETUP.md) and ask them to
  finish setup before retrying.
- If a command fails with an auth-related error mid-session, re-run
  `clor account login` to confirm the key is still valid before retrying.
