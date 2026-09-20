# Roadmap

## Current state (2026-09-20)

The Swift app is the daily driver: popup with real toggles, brightness,
resolution, closed-lid keep-awake (qualified live), login item registration,
and English/French localization. Ad-hoc or Developer ID signing both work.

## Distribution readiness (direct distribution)

- [x] **Developer ID signing** — `SIGN_IDENTITY` env var on
      `scripts/build-runclosed-app.sh` (verified with a real identity).
- [ ] **Notarization** — `xcrun notarytool submit build/RunClosed.app --wait`
      then `xcrun stapler staple`. Needs an Apple Developer Program membership.
- [ ] **Tagged release** — first `v0.2.0` tag + GitHub release with the
      signed bundle.

## Open-source hygiene

- [x] CI: build + test + bundle smoke on every push/PR (`.github/workflows/`).
- [x] Secret scanning (gitleaks) on every push/PR.
- [x] CONTRIBUTING / SECURITY / CHANGELOG / issue templates.
- [ ] **Contributor-facing compatibility matrix growth** — the matrix only
      lists what has been tested; external-display rows need hardware reports
      from contributors (see `docs/compatibility/README.md`).

## Product backlog

- [ ] **Second-display qualification** — the enable/disable path's happy case
      needs a machine with 2+ displays; on a single-display machine only the
      last-display guard is exercised.
- [ ] **Private-API disclosure** — `SLSConfigureDisplayEnabled` is private
      SkyLight. Fine for direct distribution, blocked for the App Store by
      design. If an App Store variant is ever wanted, it must drop that
      feature or find a public API.
- [ ] **A14-T2** — privileged-helper XPC endpoint (today: registration
      skeleton only; the daily app uses `sudo -n pmset` + a documented
      sudoers rule).
- [ ] **Reboot behavior of `disablesleep`** — documented as UNDOCUMENTED in
      ADR 015; the app stays fail-closed either way. A controlled reboot test
      would let the compatibility matrix state the observed behavior.

## Non-goals

- App Store submission of the private-SkyLight path.
- Extending the privileged helper without an ADR.
- Windows/Linux ports.
