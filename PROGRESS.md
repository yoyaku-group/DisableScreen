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

## G2d-prep — Unification persistence (2026-09-14)
- DONE — nouveau target `RunClosedPersistence` (lib, dépend de `RunClosedCore`) absorbe la résolution de path + écriture atomique des leases. `LeaseStore` y est `public` avec 2 inits (canonique + URL-injecté pour tests).
- DONE — `runclosed` et `RunClosedMenuBar` dépendent maintenant de `RunClosedPersistence` ; les anciens fichiers locaux (`Sources/runclosed/LeaseStore.swift`, `Sources/RunClosedMenuBar/LeaseReader.swift`) sont supprimés. Le CLI writer (`main.swift:40,109`) et le menu-bar reader (`AppMain.swift:92`) partagent désormais le même module.
- DONE — `tests/RunClosedPersistenceTests/LeaseStoreTests.swift` (5/5 verts) : round-trip save/load, missing-file → empty, reap cross-boot, reap expired, atomicité (pas de fichier temp sibling). FakeClock local pour contrôle déterministe.
- DONE — Swift test suite global : **25/25 verts** (9 Core + 11 ViewModel + 5 Persistence) ; build 0 warning ; CLI live `runclosed doctor --json` + `runclosed run --idle-only -- sh -c 'exit 7'` → exit 7 + `leases.json` round-trip `[]` ; menu-bar app lance + refresh + SIGTERM exit 143 (clean).
- DONE — ADR 011 ajoutée (DECISIONS.md) : « toute surface cross-target vit dans un module dédié, pas dupliquée ». Préparation structurelle pour G2b / G4 qui vont multiplier les writers/lecteurs de leases.
- NOT_TESTED (live) — les 5 régressions Persistence sont unit-tests avec FakeClock + URL-injectée (pas de dépendance au filesystem live) ; le round-trip end-to-end avec leases réelles est déjà couvert par le live `runclosed run --idle-only` ci-dessus.

## G2c — Lid stay-awake Swift (2026-09-14, PR #5 `runclosed-g2c-lid` ; cross-boot rework 2026-09-16)
- DONE — `LidMutationPolicy` (`Sources/RunClosedCore/`) : policy pure — refuse `prior == nil` (B1 invariant : UNKNOWN ≠ OFF), refuse no-op. Pas de référence persistence depuis Core (cycle de dépendance) — la décision d'ownership (B2) vit dans la service layer.
- DONE — `LidAssertion` protocol + `PMSetLidAssertion` (`Sources/RunClosedMacSystem/`) : backend subprocess fork+exec `pmset -a disablesleep <0|1>` + readback via `PowerReadback.lidStayAwake()` (`pmset -g`). Capture **combinée stdout+stderr** : `pmset` redirige ses warnings stderr → stdout quand stderr ≠ tty (quirk macOS détecté au live verify G2c). Readback = autoritaire — exit code pmset NON-FIABLE (`pmset` retourne 0 même quand le flag n'est pas réellement muté si l'appelant n'a pas root).
- DONE — `LidMutationService` (`Sources/RunClosedMacSystem/`) : orchestration B1 → policy → B2 ownership check (record bootID==currentBootID + ownedEnabled) → mutator → persist ownership if .verified. `restoreIfOwned()` strictement boot-matched.
- DONE — `OwnedLidAssertion` (`Sources/RunClosedPersistence/`) : persistence atomique `~/Library/Application Support/RunClosed/owned_lid.json` avec schemaVersion. **Cross-boot : `load()` retourne le record verbatim — JAMAIS de discard silencieux** (ADR 015).
- DONE — **ADR 015 rework (2026-09-16, review Ben)** : `reconcileCrossBoot()` fondé sur l'OBSERVATION — stale+OFF → purge (seul chemin d'effacement) · stale+ON → `recoveryPending` conservé, pas d'auto-mutation · stale+UNKNOWN → conservé. `status` JSON expose `recoveryPending`. Record stale ne confère pas d'ownership (`off` refuse `notOwned`).
- DONE — CLI `runclosed lid-stay-awake on|off|status`. Exit codes : 0 succès / 3 refusal (B1 unknown / no-change / notOwned) / 5 backend failure / 64 usage.
- DONE — **30 tests G2c** : `LidMutationPolicyTests` (7) + `LidMutationServiceTests` (15, avec FakeLidAssertion — dont 6 nouveaux ADR 015) + `OwnedLidAssertionStoreTests` (8 — dont 3 rework ADR 015).
- NOT_TESTED (live) — chemin happy-path (on→off complet) = **nécessite élévation root** (relie backlog A14). Reboot-comportement `disablesleep` = UNDOCUMENTED → protocole Phase 4 (opérateur présent) ; le modèle fail-closed ADR 015 doit être correct dans les deux cas.
- [DISCOVERY] Quirks `pmset` : stderr→stdout swap quand stderr ≠ tty ; exit code non-fiable sans privilège — readback `pmset -g` seul autoritaire (B2).
- [DISCOVERY] Environnement build 2026-09-16 : Xcode 26.6 → 27.0 auto-update pendant la nuit, licence non acceptée → `xcodebuild`/`swift` shims bloqués. **Workaround complet trouvé et scripté** (`scripts/dev/run-tests-xcode27.sh`) : frontend toolchain direct + `SDKROOT` + frameworks copiés dans les rpaths + `arch -arm64 xctest` — les 55 tests tournent VERTS malgré la licence non acceptée (seuls les shims sont licence-gated, pas les frontends). Unblock canonique Ben = `sudo xcodebuild -license accept` (une ligne).

## G3 — Capot
- BLOCKED_HARDWARE — un seul écran XDR intégré ; capot non testable sans Ben présent. Protocole `scripts/hardware/lid-qualification.sh` **prêt** (opt-in `RUNCLOSED_HW_OPTIN=1`, refuse sinon = vérifié ; baseline→set→témoin 10s→cycle capot→restore→verdict PASS/FAIL/INDÉTERMINÉ). `restore --owned` = stub sur cette branche (G2b display restore vit dans la PR parallèle `runclosed-g2b-display`).
- NOT_DONE (backlog) : G2 suite (UI AppKit à parité écrans, suppression launcher Python), G4 (adaptateurs Claude/Codex — **gated** : pas de droit de mutation lid avant A14 + recovery + reboot test + qualification verts), G5 (Developer ID/notarisation/rename public), A14 (helper SMAppService LaunchDaemon + XPC).
