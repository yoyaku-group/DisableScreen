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
- DONE — A01 (log dir avant FileHandler), A02 (broadcast DDC supprimé, read-only diag), A03 (modèle de propriété lid + restore-if-owned + purge stale boot), A04 (garde dernier écran au moment de l'effet + owned_disabled_displays + réactivation au lancement), A05 (résolution résultat typé + readback), A06 (launcher identity check + None → unavailable), A07 (cache = valeur appliquée, slider floor externe), A08 (test_e2e injectable, "Started.", SKIP≠PASS), A09 (cache statut off-thread), A10 (lid tri-état), A13 (bouton « Réglages Écran macOS »), A15 (LSMinimumSystemVersion 13.0), A17 (self-heal seulement sur notFound), A19 (screensDidChange coalescé).
- DONE — `tests/test_main_fixed.py` : **10/10 OK** (attentes inversées sur le main.py corrigé) ; reproductions toujours 8/8 sur l'archive → **18/18 combiné**.
- DONE — build `arch -arm64` + swap `/Applications` réversible (backup `/tmp/DisableScreen.app.bak-*` + `.old-*`) ; relance OK ; **A17 self-heal observé** (`notFound` → re-register → `enabled`) ; `test_e2e.py` sur l'app installée = tout PASS, 0 FAIL.
- NOT_TESTED (live) — toggle `pmset disablesleep` 0→1→0 réel : logique de propriété prouvée par tests unitaires A03 (pmset/boot fakes) ; le flip du flag root réel pendant que l'app tourne n'a pas été exercé pour ne pas polluer le `settings.json` partagé de l'instance live.
- NOT_DONE (backlog G3) — A11 (identité écran stable), A12 (backend partiel), A14 (helper borné remplace sudoers), A16 (bundle Swift autonome), A18 (identité de mode stable), A20/A21 (CI/Store).

## G2 — Noyau Swift + CLI + wrapper idle
- NOT_TESTED — Package.swift, RunClosedCore, RunClosedMacSystem, CLI `runclosed`, tests.

## G3 — Capot
- BLOCKED_HARDWARE — un seul écran, capot non testable sans Ben présent. Protocole `scripts/hardware/lid-qualification.sh` à préparer (opt-in).
