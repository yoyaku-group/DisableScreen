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
- DONE — `Package.swift` (swift-tools 6.0, macOS 14, zéro dépendance externe).
- DONE — `RunClosedCore` : Models (Codable, schemaVersion), Clock injectable, `LeaseEngine` (acquire idempotent, reap expiration + autre boot, decide keep-awake), `DisplayPolicy.canDeactivate` (garde dernier écran). Aucun import AppKit.
- DONE — `RunClosedMacSystem` : `DisplayInventory` (CoreGraphics read-only, capability honnête native/softwareDim + détection d'ambiguïté), `IdleAssertion` (IOPMAssertionCreateWithName), `PowerReadback` (pmset tri-état), `BootID` (sysctl).
- DONE — CLI `runclosed` : `status/displays/doctor --json`, `run [--idle-only] [--max] -- <cmd>` (préflight + assertion + lease + propagation du code de sortie + relais SIGINT/SIGTERM), `run --lid` → **exit 3** avant lancement, `restore --owned` → stub G3.
- DONE — `swift test` : **9/9 OK** (idempotence, expiration, autre boot, keep-awake états, release, dernier écran, unknown≠off, erreur≠succès).
- DONE — vérif live : `displays`/`doctor` corrects, `run --lid`→3, `run --idle-only -- sh -c 'exit 7'`→7, assertion `PreventUserIdleSystemSleep` visible dans `pmset -g assertions` pendant le run + lease dans `status`, tout libéré après.

## Audit pré-merge PR #1 (2026-09-12) — durcissement recovery/ownership
- DONE — **B1** `_set_lid_stay_awake` : pré-état `None` (illisible) → REFUSE la mutation (`precondition_unknown`, `mutated=False`), aucun write pmset, aucun ownership. Invariant UNKNOWN ≠ OFF appliqué au point de mutation.
- DONE — **B2** ownership prouvé par observation : activation ne réclame l'ownership que si `rc==0` **ET** readback `observed is True` ; désactivation manuelle ne libère que si readback `observed is False` ; `_restore_owned_lid_on_quit` ne supprime le `lid_owner` qu'après readback confirmant OFF, sinon garde le record + log `RESTORE_FAILED` (retry possible au prochain run).
- DONE — **B3** `_reactivate_owned_displays` : réécrit le record depuis le **résultat de réactivation** (IDs FAILED/exception conservés), plus jamais reconstruit depuis `disabled_displays` (vide au lancement). Writer atomique partagé `_write_owned_disabled` (temp + `os.replace`).
- DONE — **latent Swift** `LeaseStore.save` : `write(.atomic)` direct au lieu de `write(tmp)+remove(url)+move` (non atomique, crash entre remove/move = fichier de leases perdu).
- DONE — 9 régressions inversées `tests/test_main_fixed.py::RecoverySafety` (B1/B2/B3) vertes ; suite combinée **27/27** ; `swift test` **9/9** ; CLI live round-trip leases OK.
- DONE — PR #1 mergée (`b1215b5` squash sur `origin/main`) le 2026-09-14 après re-vérification (4 correctifs présents, suites vertes, CLI exit 7 propagé).

## G2a — UI Swift menu-bar READ-ONLY (2026-09-14)
- DONE — `Sources/RunClosedApp/SnapshotViewModel.swift` : ViewModel pur (no AppKit, testable Linux), `SnapshotBuilder.make()` rend le tri-état `unknown` **distinct** de `off`, `softwareDim` jamais labellisé `native`, leases filtrées par `bootID`. `SnapshotRenderer.render()` sortie texte déterministe.
- DONE — `tests/RunClosedAppTests/SnapshotViewModelTests.swift` : **11/11 verts** — couvrent UNKNOWN ≠ OFF (3 tests), honnêteté capability (3), filtrage bootID (1), leases vides (1), ambigüité affichée (1), empty displays (1), déterminisme renderer (1).
- DONE — `Sources/RunClosedMenuBar/` : executable AppKit (LSUIElement via `accessory`). `NSStatusItem` + `NSMenu` rendu depuis `SnapshotBuilder`. Mutations désactivées (grisées) avec tooltip « G2b/G2c » — visibles mais désactivées (sincérité, pas absence). Refresh 5 s + coalescing 0.5 s sur `didChangeScreenParametersNotification` (A19). Lectures hors main-thread (A09).
- DONE — détecté pendant l'écriture : la détection d'ambiguïté vivait dans `DisplayInventory` mais le `SnapshotBuilder` (qui peut recevoir des snapshots d'un autre backend en G2b) doit aussi la recalculer — **défense en profondeur**, le test `testAmbiguousDisplayFlagged` a coincé puis a été fixé par le recalcul dans le builder.
- DONE — `Sources/RunClosedMenuBar/LeaseReader.swift` : mini-lecteur read-only local (10 lignes, atomique + reap). Le canonique `LeaseStore` reste dans le target `runclosed` ; unification cross-target en G2b.
- DONE — `Package.swift` : ajout targets `RunClosedApp` (lib) + `RunClosedMenuBar` (executable) + `RunClosedAppTests` (XCTest).
- NOT_TESTED (live) — chemin interactif UI (clic menu « Rafraîchir », navigation éléments) — l'app a été lancée en background 3 s, démarrage + cycle de refresh + SIGTERM propres (`exit=143`), mais l'UI n'a pas été cliquée par un humain. Couverture suffisante pour G2a (read-only, zéro mutation possible).
- BLOCKED_HARDWARE (inchangé) — G2b/G2c : mutation écran nécessite 2e écran, mutation `pmset disablesleep` = NOT_TESTED live (flag root), G3 capot inchangé.

## G3 — Capot
- BLOCKED_HARDWARE — un seul écran XDR intégré ; capot non testable sans Ben présent. Protocole `scripts/hardware/lid-qualification.sh` **prêt** (opt-in `RUNCLOSED_HW_OPTIN=1`, refuse sinon = vérifié ; baseline→set→témoin 10s→cycle capot→restore→verdict PASS/FAIL/INDÉTERMINÉ). `restore --owned` = stub.
- NOT_DONE (backlog) : G2 suite (UI AppKit à parité écrans, suppression launcher Python), G4 (adaptateurs Claude/Codex), G5 (Developer ID/notarisation/rename public).
