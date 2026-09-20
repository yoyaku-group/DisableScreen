# Security Policy

## Reporting a vulnerability

Please report security issues privately via GitHub's
[Security Advisories](../../security/advisories/new) rather than opening a
public issue. We aim to acknowledge reports within a few days.

## What counts as sensitive here

RunClosed runs as the logged-in user and can:

- change display topology via a private macOS API,
- flip the root-owned `pmset disablesleep` flag through a user-configured
  `sudo -n` sudoers rule (see README § Install),
- register a login item and a LaunchDaemon **skeleton** (registration only —
  the daemon performs no privileged work today).

Reports about any of the following are in scope:

- privilege escalation beyond the whitelisted `pmset` command,
- command injection through display names, mode strings, or process arguments,
- state confusion where the app reports success without a verified read-back,
- unsafe restore paths (e.g. re-enabling a display or flag that the app did not
  own).

## Design guarantees that hold today

- The app never runs a shell; subprocesses are `exec`'d with fixed argument
  vectors (`pmset`, `sudo -n`, `sysctl`).
- `sudo -n` never prompts and never caches credentials.
- The privileged helper daemon has no `MachServices`, no `RunAtLoad`, and no
  privileged endpoint.
- Ownership records are boot-scoped and restored only when the observable
  state still matches what the app set.

## Supported versions

The `main` branch is the only supported line until a first tagged release.
