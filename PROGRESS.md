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

## G2b — Display mutation Swift (2026-09-14)
- DONE — `DisplayMutationPolicy` (`Sources/RunClosedCore/`) : pure policy, `canDisable(target:activeIDs:)` + `canEnable(target:knownIDs:)`. Refuse stale-target (id hors de l'actif) et last-active guard (invariant 4).
- DONE — `DisplayMutator` protocol + `SLSDisplayMutator` (`Sources/RunClosedMacSystem/`) : backend réel wrappant `SLSConfigureDisplayEnabled` via `dlsym` sur SkyLight (même chemin que Python ctypes). Readback post-write via `DisplayInventory.activeIDs()` — vérifie que l'état demandé est bien l'état observé (`.verified` vs `.failed`). Si SkyLight indisponible : `.unknown` au lieu de mentir.
- DONE — `DisplayMutationService` (`Sources/RunClosedMacSystem/`) : orchestration policy + mutation + persistence + réactivation-on-launch. **B3 strict** : `restoreOwned()` ré-écrit le record depuis l'OUTCOME (FAILED/exception conservés), jamais depuis la map live.
- DONE — `OwnedDisabledDisplays` (`Sources/RunClosedPersistence/`) : persistence atomique `~/Library/Application Support/RunClosed/owned_displays.json` avec schemaVersion. **Cross-boot discard** au load : un record d'un boot précédent est jeté sans tenter de re-enable aveuglément (B3 strict — re-enable sur un autre boot pourrait rallumer un écran débranché).
- DONE — CLI `runclosed disable <id>` / `enable <id>` / `restore --owned`. Exit codes : 0 succès / 3 refusé (stale / last-active / unknown) / 5 backend failure **ou restauration partielle** (ADR 014) / 64 usage.
- DONE — **21 nouveaux tests verts** : `DisplayMutationPolicyTests` (6) + `DisplayMutationServiceTests` (9, avec FakeDisplayMutator) + `OwnedDisabledDisplaysStoreTests` (6). Suite globale **46/46 verts** (9 Core originaux + 6 policy + 5 Lease + 6 Owned + 9 Service + 11 ViewModel). Build 0 warning.
- DONE — Live verify (1 écran XDR) : `disable 1` → exit 3 (refused, last active). `enable 1` → exit 5 (backend : `kCGErrorCannotComplete` — re-enable d'un écran déjà actif est un no-op rejeté par CoreGraphics, comportement attendu sur 1 écran). `restore --owned` → exit 0, JSON `stillOwned: []`. `doctor` + `displays` + `status` inchangés.
- NOT_TESTED (live) — chemin happy-path (disable 2e écran → enable) = `BLOCKED_HARDWARE` (1 écran sur cette machine). La logique est couverte par les 9 tests Service avec fake mutator qui simulent exactement le round-trip. Le `enable 1` exit 5 sur 1 écran valide le policy backend handshake (la requête atteint le backend et le backend refuse proprement) — c'est la 2e moitié de l'invariant ADR 009 (`success d'API ≠ succès observable`).
- ADR 012 ajoutée (DECISIONS.md).


## G2b-corrections — Pré-merge correctness fixes (2026-09-15, Phase 1)
- DONE — **défaut #1 résolu** : `SLSDisplayMutator.setEnabled` retournait `action: enabled ? .deactivate : .deactivate` (5 sites, `DisplayMutation.swift:62,73,85,96,113`). Les deux branches identiques masquaient l'opération dans tous les `OperationResult` (logs, diagnostics, adaptateurs futurs). Corrigé via nouveau case `.activate` dans `DisplayAction` (Core), 5 sites mis à `enabled ? .activate : .deactivate`. Tests `FakeDisplayMutator` aligné sur la même logique (miroir du vrai backend).
- DONE — **défaut #2 résolu** : `cmdRestoreOwned` retournait `exit 0` même quand `stillOwned.count > 0` (restauration partielle = échec opérationnel pour un caller automatisé — agents/scripts interprètent `0 = succès` et zappent le retry). Corrigé : `return stillOwned.isEmpty ? 0 : 5` (cohérent avec exit 5 = backend failure du même CLI). Docstring + ADR 014 explicite la sémantique.
- DONE — **4 nouveaux tests verts** : `testDisablePropagatesDeactivateAction`, `testEnablePropagatesActivateAction`, `testRestoreOwnedPropagatesActivateAction`, `testRestoreOwnedReturnsNonEmptyListOnPartial`. Suite globale **72/72 verts** (était 68/68, +4). Build 0 warning.
- ADR 014 ajoutée (DECISIONS.md).
- Note : le défaut #3 (drift `PROGRESS.md §G3`) est corrigé dans la branche omnibus (`66963a9`), pas dans PR B — voir `git log` du PR omnibus pour le diff exact.


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

## A14 — Helper privilégié LaunchDaemon (T1 packaging + registration E2E-qualifiée 2026-09-17 ; T2 XPC NOT_STARTED)
- DONE — `RunClosedHelperSupport` : `RunClosedHelperDescriptor` (plist/binary/label + `bundleProgramRelativePath` + opération bornée unique) + `DaemonStatus` (4 états SMAppService mappés 1:1 + unknown, sémantique macOS 26 documentée ADR 018) + `DaemonRegistrar` protocol (seam de test, inclut `openLoginItemsSettings()`) + `SMAppServiceDaemonRegistrar` (production) + `HelperLifecycleService` (`Report` honest : `xpcImplemented:false` + `lastOperationSucceeded` jamais avalé).
- DONE — `RunClosedHelper` daemon executable : start + log + SIGTERM. **Aucune opération privilégiée.**
- DONE — Plist : **`BundleProgram` relatif** (`Contents/MacOS/runclosed-privileged-helper`) — PAS `Program` absolu ; **sans `RunAtLoad`/`KeepAlive`/`MachServices`** : le daemon ne tourne jamais en T1 ; régression unitaire plist ↔ descriptor.
- DONE — `scripts/build-runclosed-app.sh` : assemble `RunClosed.app` (MacOS/{RunClosed, runclosed-cli, runclosed-privileged-helper} + Library/LaunchDaemons/{plist} + Info.plist LSUIElement) + `SIGN_IDENTITY` + `codesign --verify --strict`. CLI embarqué = `runclosed-cli` (APFS insensible à la casse : `runclosed` écrasait `RunClosed` — détecté en E2E).
- DONE — CLI `runclosed helper status/register/login-items/unregister`.
- DONE — **38/38 tests** (36 + 2 : register depuis `notFound` (réalité macOS 26), no-op sur `requiresApproval`).
- DONE — **E2E réel (macOS 26.6, .app Developer ID YZYJJPX484 installé /Applications)** : `status` notRegistered → `register` (**requiresApproval, exit 0**, wrapper corrigé ADR 018) → `status` requiresApproval → `unregister` → notRegistered → `status` notRegistered. `codesign -dv` app + daemon = TeamIdentifier YZYJJPX484. RunClosed n'a émis **aucun pmset** ; daemon jamais lancé (aucun trigger). NB : le `SleepDisabled=1` observé pendant l'E2E est tenu par l'app quotidienne **DisableScreen** (PID 57018, log « lid stay-awake … observed=True » daté 2026-09-16 21:21) — antérieur et indépendant de l'E2E.
- NOT_TESTED (live, restant) — **approbation humaine Login Items → `enabled`** (geste opérateur ; re-register = 1 commande) · XPC (T2) · `setDisableSleep` live (T2, après code-signing requirement).
- ADR 016 + 017 + 018 (DECISIONS.md).

## G2d — POPUP UI À TOGGLES, PARITÉ PYTHON (2026-09-20) — branche `agent/opencode/20260919/4784-g2d-popup-toggles`

**Livré** — l'app Swift remplace l'app Python pour l'usage quotidien : popup NSPanel ancré sous l'icône, NSSwitch par écran, slider luminosité, sélecteur résolution, switch capot, switch login item, résumé leases, Quit. Constantes de layout portées depuis le panneau Python (280pt, rangées 46/36/34/34).

- DONE — `PopupPanel` + `PopupState` (AppKit) : rendu pur, chaque contrôle porte un tag display-id + cible les actions @objc du delegate.
- DONE — `SudoPMsetLidAssertion` : chemin `sudo -n pmset -a disablesleep <0|1>` — exactement la mutation M6 de l'app Python (`/etc/sudoers.d/disablescreen-pmset`, NOPASSWD). Readback autoritaire ; jamais de prompt (`sudo -n`).
- DONE — **DÉFAUT RACINE RÉSOLU — parsing `pmset -g`** : `PowerReadback` splittait sur l'espace littéral, mais `pmset` sépare par TABULATION (` SleepDisabled\t\t1`). Le readback retournait `false` en permanence → tout toggle capot était rapporté en échec pendant que le flag était réellement muté (cause exacte du « ça ne marche pas » du 2026-09-20). Fix : split sur toute suite d'espaces + 6 tests de régression ; `LidReadback.waitFor()` = retry borné 5×150ms (le flag noyau peut accuser un temps de retard sur le retour de `pmset`).
- DONE — `DisplayModes` (CoreGraphics public) : liste des modes dédupliquée (meilleure fréquence par géométrie, tri décroissant) + `set` typé avec readback (A05). `DisplayModeSelection` (Core, pur) : 8 tests.
- DONE — `DisplayBrightness` : dlopen CoreDisplay depuis `/System/Library/Frameworks/` — le chemin PrivateFrameworks retourne nil en dlopen Swift direct (l'app Python ne le résolvait que via le cache dyld ; mesuré 2026-09-20). Luminosité native builtin, une seule cible (invariant 1).
- DONE — `DimOverlayController` : overlay noir cliquable-transparent pour les externes (M4/A02), plancher 0.08 (A07 : la valeur cachée est celle appliquée).
- DONE — `LoginItemControl` (MacSystem, partagé popup + CLI) : `runclosed login-item status|on|off` (0 / 4=requiresApproval / 5).
- DONE — switch écran grisé quand cible = dernier écran actif (parité Python) — le raccourci `experimental` précédent contournait le garde.
- DONE — Cutover complet : app signée Developer ID installée `/Applications`, ancienne app Python `--unregister` + arrêtée + retirée (backup zip + dossier `.retired` réversibles), alias Desktop → RunClosed, login item `RunClosed` enregistré (requiresApproval — approbation Ben en 1 clic).
- **Preuves live (UI, via cliclick, 2026-09-20)** : toggle capot ON → `pmset -g` SleepDisabled 1 + `ownedByThisBoot: true` ; re-toggle OFF → 0 + ownership libéré. Slider luminosité rendu à 100%. Popup capturé (capture d'écran).
- DONE — **i18n (EN base / FR localisé)** : clés = strings anglaises (fallback natif = défaut produit), `fr.lproj/Localizable.strings` copié dans le bundle par le build script, `CFBundleDevelopmentRegion=en` + `CFBundleLocalizations=[en,fr]`. Renderer dev en anglais. Preuve in-bundle : `-AppleLanguages '(en)'` → « Keep awake with lid closed » ; session fr_FR réelle → table française ; langue non shipée (de) → fallback anglais.
- DONE — **Préparation open source** : README réécrit pour l'app Swift, CONTRIBUTING, SECURITY, CHANGELOG, CI GitHub Actions (build+test+smoke bundle), scan gitleaks (+ config ciblée), issue templates, boot UUID retiré de `evidence/environment.md`, scan historique complet (aucun secret — seules les mentions documentaires du sudoers).
- NOT_TESTED — chemin 2 écrans (disable/enable externe) = BLOCKED_HARDWARE inchangé ; approbation Login Items côté Ben ; reboot-comportement `disablesleep` (ADR 015, Phase 4).
- ADR 019 (DECISIONS.md).

## G3 — Capot
- **DONE (live, 2026-09-20)** — qualification capot fermé par Ben : toggle ON depuis le popup (read-back `pmset -g` = `SleepDisabled 1`, record d'ownership `ownedEnabled: true` pour le boot courant), **capot physiquement fermé, la machine est restée éveillée** ; retour OFF → flag 0 + ownership libéré. La matrice de compatibilité est mise à jour (`docs/compatibility/README.md`).
- BLOCKED_HARDWARE (écran) — un seul écran XDR intégré ; Protocole `scripts/hardware/lid-qualification.sh` **prêt** (opt-in `RUNCLOSED_HW_OPTIN=1`, refuse sinon = vérifié ; baseline→set→témoin 10s→cycle capot→restore→verdict PASS/FAIL/INDÉTERMINÉ). `restore --lid` reste un **G3 stub** (chemin capot non qualifié) ; `restore --owned` = **G2b live** (correctif Phase 1 — voir §G2b-corrections).
- NOT_DONE (backlog) : G2 suite (UI AppKit à parité écrans, suppression launcher Python), G4 (adaptateurs Claude/Codex), G5 (Developer ID/notarisation/rename public).

## G5 — Distribution readiness : notarisation + première release (2026-09-20)

- DONE — **Hardened runtime** : les 4 slices (helper daemon, CLI, binaire principal, bundle) sont signés `--options runtime --timestamp` dans `scripts/build-runclosed-app.sh` — prérequis notarisation. Vérifié : `flags=0x10000(runtime)`, timestamp présent, `codesign --verify --strict` OK.
- DONE — **Version 0.2.0** (build 2) dans le script de build (SSOT du plist généré) ; `CHANGELOG.md` promu `[0.2.0] - 2026-09-20`.
- DONE — **Notarisation acceptée** : build propre (`.build` purgé) → zip `ditto` → `notarytool submit --keychain-profile YOYAKU-NOTARY --wait` → **Accepted** (id `d1faa763-d938-4a6c-bfee-951f2f55bc7c`) → `stapler staple` → `spctl -a -vv` = **accepted, source=Notarized Developer ID**. Le ticket survit au zip (revalidé sur l'archive extraite).
- DONE — **Profil keychain `YOYAKU-NOTARY` recréé et validé** (il était absent de ce Mac ; `webmaster-claude-config/scripts/build-enrolment-dmg.sh` attend ce profil et tombait en WARN « no notarytool keychain profile »).
- DONE — **Installé /Applications** (bundle précédent sauvegardé `~/DisableScreen/backups/RunClosed.app.pre-notarize-20260920-210327`) ; smoke live sur le build notarisé : popup rendu (capture d'écran), brightness CoreDisplay OK, `enable 1` → exit 5 (chemin SkyLight privé identique à l'ancien build), capot toujours ON + ownership ré-adopté (`ownedByThisBoot: true`), aucun crash report.
- DONE — **Release v0.2.0** : tag + GitHub release avec `RunClosed-0.2.0.zip` (sha256 `9507c5cc284c256fd8d1058f35a3f7b41173c4e5912672bd2f57edb4dc1d92d6`).
- Restant G5 — décision **rename public** (RunClosed vs DisableScreen) = décision Ben. Login item = `requiresApproval` (approbation Ben en 1 clic dans Réglages Système ; état hérité du cutover G2d, pas une régression).
- [DEFECT:contradiction] — `runclosed doctor` rapporte `lid.backend="unqualified"` (hardcodé `Sources/runclosed/main.swift:64`) alors que `docs/compatibility/README.md` enregistre le chemin capot **PASS (2026-09-20)**. Reformuler le doctor pour distinguer « toggle app qualifié live » de « helper CLI `run --lid` encore stub ».
