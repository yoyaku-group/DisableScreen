# Contributing

Thanks for looking at RunClosed. This is a small, safety-conscious macOS
utility; the highest-value contributions are bug reports with evidence and
targeted fixes that respect the invariants below.

## Before you start

- Read [README § Safety model](README.md#safety-model) and skim `DECISIONS.md`.
  The ADR table explains *why* several "obvious" shortcuts are forbidden here.
- Build and run the tests locally:

```bash
swift build
swift test
bash scripts/build-runclosed-app.sh    # assembles build/RunClosed.app
```

- For UI changes, run the built app (`open build/RunClosed.app`) and verify the
  rendered result — "it compiles" is not a verification.

## Ground rules

- **Reads before writes.** Every mutation must be preceded by an observable
  baseline and followed by a read-back that decides success.
- **Never render UNKNOWN as OFF.** The tri-state (`on` / `off` / `unknown`) is
  load-bearing; collapsing it has caused real misdiagnoses (see `DOCS`.
- **One target per command.** No broadcast writes.
- **No new dependencies** without a decision recorded in `DECISIONS.md`.
- **Pure logic lives in `RunClosedCore`** (no AppKit, no system calls) so it is
  unit-testable; system surfaces live in `RunClosedMacSystem` behind protocols.

## Pull requests

1. One focused change per PR.
2. Include the exact commands you ran and their observed outcome in the PR
   description (tests, live checks, screenshots for UI changes).
3. If you changed behavior that a test pinned, update the test in the same PR
   and explain why the old expectation was wrong.
4. Commit messages: plain English, imperative mood, no emoji.

## Reporting bugs

Open an issue with:

- macOS version and Mac model,
- display setup (built-in only? external? which),
- what you did, what you expected, what happened,
- any output from:

```bash
/Applications/RunClosed.app/Contents/MacOS/runclosed-cli doctor
/Applications/RunClosed.app/Contents/MacOS/runclosed-cli status
```

For lid-related issues, include `pmset -g | grep SleepDisabled` before and
after the toggle.

## Out of scope

- App Store submission work for the private-SkyLight path.
- New privileged surfaces. The privileged helper (`RunClosedHelper*`) is
  intentionally a registration skeleton; extending it requires an ADR.
