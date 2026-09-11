# PROGRESS — RunClosed G0–G2

Statuts stricts : **DONE** (fait + vérifié) · **FAILED** · **NOT_TESTED** · **BLOCKED_HARDWARE**.

## G0 — Preuves
- DONE — mission + worktree lié (`yy mission`, branche `agent/claude/20260911/…`).
- DONE — instance dev doublon (PID 7950) arrêtée ; app `/Applications` (PID 1394) intacte.
- DONE — `evidence/manifest.json` (sha256 des 5 fichiers legacy @ `a7665b5`).
- DONE — `evidence/environment.md` (M5 Max, macOS 26.6, Xcode 26.6, Swift 6.3.3, PyObjC 10.3.1, sudoers réel, 1 écran).
- DONE — `tests/legacy_defects/test_reproductions.py` : **8/8 OK** contre l'archive (défauts A01–A08 présents).
- DONE — `docs/mutation-inventory.md` (M1–M8).

## G1 — Stabiliser main.py
- NOT_TESTED — A01, A02, A03, A04, A05, A06, A07, A08, A09, A10, A13/A14, A15, A17, A19 (à venir, chacun commit + test inversé).

## G2 — Noyau Swift + CLI + wrapper idle
- NOT_TESTED — Package.swift, RunClosedCore, RunClosedMacSystem, CLI `runclosed`, tests.

## G3 — Capot
- BLOCKED_HARDWARE — un seul écran, capot non testable sans Ben présent. Protocole `scripts/hardware/lid-qualification.sh` à préparer (opt-in).
