# TEST_RESULTS — RunClosed

Commandes réellement exécutées. Aucun résultat inventé.

## G0 — reproductions des défauts d'archive

Un test qui **PASSE** = le défaut est **présent** dans l'archive `a7665b5`. Hors matériel : frameworks stubés, backends monkeypatchés, aucune écriture display/pmset réelle. Env : Apple M5 Max, macOS 26.6, Python 3.12.4 framework + PyObjC 10.3.1.

```
$ python3.12 -m unittest tests.legacy_defects.test_reproductions
test_01_first_launch_log_parent_not_created ......................... ok   # A01
test_02_iokit_brightness_writes_every_matching_service .............. ok   # A02 (broadcast [201,202])
test_03_resolution_returns_success_when_all_native_calls_fail ....... ok   # A05 (True malgré 3 échecs)
test_04_zero_brightness_state_does_not_match_applied_floor .......... ok   # A04/A07 (cache 0.0 vs floor 0.08)
test_05_launcher_path_accepts_python_bundle_without_identity_check ... ok   # A06
test_06_clean_termination_has_no_sleep_policy_cleanup ............... ok   # A03 (quit ne restaure pas disablesleep)
test_07_last_display_guard_is_missing_in_action_handler ............. ok   # A04 (dernier écran désactivé)
test_08_e2e_log_expectations_do_not_match_current_source ............ ok   # A08

Ran 8 tests in 0.76s
OK
```

## G1 — attentes inversées sur le main.py corrigé + e2e sur l'app installée

```
$ python3.12 -m unittest tests.test_main_fixed tests.legacy_defects.test_reproductions
Ran 18 tests in ~1.0s
OK                          # 10 inversés (fixed) + 8 reproductions (archive), rc=0
```

Livraison locale (build arm64 + swap /Applications, réversible) :
```
$ ./build.sh            → Built DisableScreen.app (adhoc, com.benjaminbelaga.DisableScreen)
# swap + relance
log: [SELF-HEAL] login item re-registered (signature changed by rebuild)   # A17 vérifié
log: Started. Displays: [1] | SkyLight=True CoreDisplay=True
$ .../MacOS/DisableScreen --status → enabled
$ python3.12 test_e2e.py → tous PASS, 0 FAIL (skips 0)
```

NOT_TESTED (live) : toggle pmset disablesleep 0→1→0 réel (logique prouvée par A03 unit tests ; non exercé sur le flag root pour ne pas perturber l'instance live).

## G2 — noyau Swift + CLI + wrapper idle

```
$ arch -arm64 swift build   → Build complete! (aucun warning)
$ arch -arm64 swift test    → Executed 9 tests, with 0 failures   (LeaseEngine/DisplayPolicy/ModelHonesty)
```

Vérif CLI live (M5 Max, macOS 26.6) :
```
$ runclosed displays --json   → [ builtin, brightness=supported/native, mode 1728x1117 ]
$ runclosed doctor  --json    → lid.backend="unqualified", idleAssertion.capability="supported", lidStayAwake="off"
$ runclosed run --lid -- true             → exit 3 (refusé avant lancement)
$ runclosed run --idle-only -- sh -c 'exit 7'  → exit 7 (code propagé)
$ runclosed run --idle-only -- sleep 4 &  → pmset -g assertions montre
    pid …(runclosed): PreventUserIdleSystemSleep named: "runclosed run: sleep 4"
   status --json (mid-run) → keepAwake=true, 1 lease "working"
   status --json (après)   → keepAwake=false, 0 lease ; 0 assertion runclosed
```

## G3
BLOCKED_HARDWARE — `scripts/hardware/lid-qualification.sh` refuse sans `RUNCLOSED_HW_OPTIN=1` (vérifié, exit 3). Non exécuté (un seul écran, capot).

## Audit pré-merge PR #1 (2026-09-12) — 3 défauts recovery/ownership + 1 latent Swift

Revue externe (ChatGPT) validée ligne-à-ligne contre le code réel puis corrigée. 4 régressions inversées + suite existante toujours verte.

```
$ python3.12 -m unittest tests.test_main_fixed tests.legacy_defects.test_reproductions
Ran 27 tests in 0.55s
OK          # 19 fixed (dont 9 RecoverySafety B1/B2/B3) + 8 reproductions archive
```

Nouvelles régressions (`tests/test_main_fixed.py::RecoverySafety`) :
```
test_b1_unknown_prestate_blocks_mutation ................ ok  # pre-read=None → 0 pmset, 0 owner
test_b2_activation_claims_ownership_only_when_readback_true  ok  # rc=0 + observed False → pas d'owner mensonger
test_b2_manual_deactivation_releases_only_when_readback_off  ok  # disable rc=0 + still ON → owner conservé
test_b2_restore_keeps_ownership_on_rc_failure ........... ok  # restore rc!=0 → RESTORE_FAILED, owner gardé
test_b2_restore_keeps_ownership_when_readback_still_on .. ok  # restore rc=0 + still ON → owner gardé
test_b2_restore_clears_ownership_only_when_verified_off . ok  # readback OFF → owner libéré
test_b3_only_failed_display_id_is_retained ............. ok  # 2 owned, 1 OK + 1 FAIL → seul le FAIL reste
test_b3_exception_keeps_display_id ..................... ok  # backend lève → id conservé
test_b3_all_recovered_clears_list ..................... ok  # tous OK → liste vide
```
Logs observés confirmant le fix (extraits) :
```
[QUIT] RESTORE_FAILED disablesleep observed=True rc=1 → keeping owner for retry
[LAUNCH] re-enable owned display 102: sls_ok=True online=False → FAILED
```

Swift (noyau inchangé + fix atomicité `LeaseStore.save`) :
```
$ arch -arm64 swift build   → Build complete! (aucun warning)
$ arch -arm64 swift test    → Executed 9 tests, with 0 failures
$ runclosed run --idle-only -- sh -c 'exit 7'   → exit 7
$ runclosed doctor --json                       → idleAssertion supported, lid unqualified
$ cat …/RunClosed/leases.json (après run)       → []  (round-trip OK, non torn)
```

NOT_TESTED (live, inchangé) : flip `pmset disablesleep` 0→1→0 réel (logique prouvée par unit tests B1/B2 ; non exercé sur le flag root live). e2e non ré-exécuté sur ces fixes (l'app installée dans `/Applications` est le build G1 d'hier, pas encore reswappée — les fixes recovery sont couverts par unit tests, pas par l'e2e du binaire installé).

## G2a — UI Swift menu-bar READ-ONLY (2026-09-14)

ViewModel pur + executable AppKit. Zéro mutation possible (G2b/G2c) ; affiordances présentes mais grisées avec tooltip explicite.

```
$ arch -arm64 swift build --product RunClosedMenuBar → Build complete, 0 warning
$ arch -arm64 swift test → Executed 20 tests, with 0 failures   (9 Core + 11 ViewModel)
$ /Library/.../python3.12 -m unittest tests.test_main_fixed tests.legacy_defects.test_reproductions
   → Ran 27 tests in 0.587s · OK
$ arch -arm64 swift build → Build complete, 0 warning
$ build/.../runclosed run --idle-only -- sh -c 'exit 7'  → exit 7
$ build/.../RunClosedMenuBar &  sleep 3 ; kill -TERM $!   → exit 143 (SIGTERM, démarrage + refresh + arrêt propres)
```

Nouvelles régressions (`tests/RunClosedAppTests/SnapshotViewModelTests`, **11/11**) :
```
testLidUnknownIsNeverRenderedAsOff  ok    # UNKNOWN power jamais "off"
testLidOnRendersOn                  ok
testLidOffRendersOff                ok
testSoftwareDimBackendNeverLabeledNative  ok   # capability softwareDim jamais "native"
testBuiltinNativeBackendLabeledNative     ok
testBrightnessUnknownRendersUnknown        ok
testLeasesFromOtherBootFiltered            ok   # leases d'un autre bootID filtrées
testNoLeasesRendersNone                    ok
testAmbiguousDisplayFlagged                ok   # recalcul d'ambigüité dans le builder (defence-in-depth)
testNoDisplaysRendersEmpty                 ok
testRendererIsDeterministic                ok   # même entrée → même sortie
```

NOT_TESTED (live) — clic interactif dans le menu NSMenu (les éléments sont désactivés par design). Démarrage + cycle de refresh + arrêt validés. Le toggle écran/lid reste **visible mais grisé** (sincérité : l'affordance est présente, le tooltip pointe G2b/G2c).

## G2d-prep — Unification persistence (2026-09-14)

`runclosed` writer + `RunClosedMenuBar` reader partagent maintenant `RunClosedPersistence.LeaseStore`. Refactor T2, blast radius ≤1 (un repo, comportement externe inchangé), rollback = `git revert`.

```
$ arch -arm64 swift build   → Build complete, 0 warning
$ arch -arm64 swift test    → Executed 25 tests, with 0 failures (9 Core + 11 ViewModel + 5 Persistence)
$ ./.build/.../runclosed doctor --json                     → JSON OK (bootID lu, displays=1)
$ ./.build/.../runclosed run --idle-only -- sh -c 'exit 7'  → exit 7
$ cat ~/Library/Application\ Support/RunClosed/leases.json → []   (round-trip propre)
$ ./.build/.../RunClosedMenuBar & sleep 3 ; kill -TERM $!  → exit 143 (SIGTERM, clean)
```

Nouvelles régressions `tests/RunClosedPersistenceTests/LeaseStoreTests` (5/5) :
```
testRoundTripPreservesLeases           ok    # save+load, lease identique (bootID, deadline, owner)
testMissingFileReturnsEmptyEngine      ok    # load sur fichier absent → engine vide
testReapOnLoadDropsOtherBootLeases     ok    # lease boot-B → reaped sous clock boot-A
testReapOnLoadDropsExpiredLeases       ok    # deadline dépassée → reaped
testAtomicWriteLeavesNoTempFile        ok    # aucun temp sibling après save (rename atomique)
```

NOT_TESTED (live) — les 5 tests utilisent FakeClock + URL-injectée (zéro dépendance filesystem live) ; le round-trip end-to-end avec leases réelles est validé par le `runclosed run --idle-only` ci-dessus.


## G2c — Lid stay-awake Swift (2026-09-14, PR #5 ; cross-boot rework 2026-09-16)

`LidMutationPolicy` (pure, Core) + `LidAssertion` protocol + `PMSetLidAssertion` (subprocess wrapper) + `LidMutationService` (orchestration B1+B2 invariants + reconcile cross-boot ADR 015) + `OwnedLidAssertion` (atomic, load verbatim + purge explicite). CLI `lid-stay-awake on|off|status`. Architecture pmset fork+exec : exit code non-fiable → readback `pmset -g` autoritaire. Cross-boot fail-closed : BOOT CHANGE ≠ PROOF OF RESTORATION (ADR 015).

**Live verify (machine Ben, non-root, 2026-09-14, commit omnibus `c386aa7` — logique identique re-structurée dans cette PR)** :
```
$ pmset -g | grep SleepDisabled  → SleepDisabled 0 (baseline)
$ runclosed lid-stay-awake status    → exit 0, JSON observed:"off", ownedByThisBoot:false, recoveryPending:false
$ runclosed lid-stay-awake on        → exit 5, message:
   backend failed: '/usr/bin/pmset' must be run as root... | readback: observed=false, expected=true
$ runclosed lid-stay-awake status    → exit 0, JSON unchanged (B2 honest refuse,
                                        pas de fausse réclamation ownership)
$ runclosed lid-stay-awake off       → exit 3, noChangeRequested (policy no-op guard)
$ pmset -g | grep SleepDisabled  → SleepDisabled 0 (état inchangé, cycle propre)
```

**Build 2026-09-16 (environnement dégradé — voir §Environment note)** :
```
$ SDKROOT=…/MacOSX.sdk arch -arm64 …/XcodeDefault.xctoolchain/usr/bin/swift build
   → Build complete! (0 warning)
```

Nouvelles régressions G2c (30 attendus) :

`LidMutationPolicyTests` (7) :
```
testSetOnAllowedWhenPriorIsOff                       ok
testSetOnRefusedWhenPriorIsOn                        ok   # no-op guard
testSetOnRefusedOnUnknownPrior                       ok   # B1 invariant
testSetOffAllowedWhenPriorIsOn                       ok
testSetOffRefusedWhenPriorIsOff                      ok   # no-op guard
testSetOffRefusedOnUnknownPrior                      ok   # B1 invariant
testPolicyIsDeterministic                            ok
```

`LidMutationServiceTests` (15, avec FakeLidAssertion — dont 6 nouveaux ADR 015) :
```
testSetOnRefusedOnUnknownPrior                                ok   # mutator jamais invoqué
testSetOffRefusedOnUnknownPrior                               ok   # mutator jamais invoqué
testSetOnSucceedsWhenPriorIsOff                                ok   # B2 readback → ownership claim
testSetOnOnBackendFailureDoesNotClaimOwnership                 ok   # B2 failure → record vide
testSetOnRefusedWhenAlreadyOn                                  ok   # no-op guard (policy catches first)
testSetOffRefusedWhenWeDoNotOwn                                ok   # mutator jamais invoqué (B2)
testSetOffSucceedsAndReleasesOwnershipWhenWeOwn                ok   # restore releases ownership
testRestoreIfOwnedNoOpsWhenNothingOwned                        ok
testRestoreIfOwnedPerformsRestoreWhenOwned                    ok   # mutator exactement 1 appel
testReconcileStaleBootObservedOffPurges                       ok   # ADR 015: seul chemin de purge
testReconcileStaleBootObservedOnKeepsRecoveryPending          ok   # ADR 015: conservé, pas d'auto-mutation
testReconcileStaleBootUnknownKeepsRecoveryPending             ok   # ADR 015: UNKNOWN ≠ OFF
testReconcileSameBootRecordNoOp                               ok
testHasStaleRecoveryPendingFlagsStaleRecordOnly               ok
testSetOffRefusesEvenWithStaleOwnershipRecord                 ok   # stale ≠ ownership sur le nouveau boot
```

`OwnedLidAssertionStoreTests` (8 — dont 3 rework ADR 015) :
```
testRoundTripPreservesOwnership        ok
testMissingFileReturnsEmptyRecord      ok   # no phantom ownership
testCorruptFileReturnsEmptyRecord      ok   # B3 strict
testLoadNeverDiscardsStaleBootRecord   ok   # ADR 015: verbatim, remplace testStaleBootRecordIsDiscarded
testRepeatedLoadsNeverEraseStaleRecord ok   # ADR 015: boot change seul n'efface jamais
testPurgeClearsTheRecordExplicitly     ok   # ADR 015: purge = décision explicite
testAtomicWriteLeavesNoTempFile        ok
testRecordSchemaVersionIsCarried       ok
```

**⚠ Environment note (2026-09-16) — workaround toolchain Xcode 27** : Xcode auto-update 26.6 → 27.0 cette nuit, licence non acceptée → `swift`/`xcodebuild`/`install_name_tool` shims refusent (`You have not agreed to the Xcode license agreements`). Workaround utilisé (script `scripts/dev/run-tests-xcode27.sh`) : build via le frontend toolchain direct (`Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --build-tests` + `SDKROOT` explicite), frameworks XCTest/Testing copiés dans les rpaths du `.build`, puis run via `arch -arm64 …/usr/bin/xctest <bundle>` (le shim seul est licence-gated, pas les frontends). **Résultat : les 55 tests de la branche tournent VERTS malgré l'environnement dégradé** (16 Core + 13 Persistence + 15 MacSystem + 11 App, 0 failures). **Unblock Ben définitif (une ligne) : `sudo xcodebuild -license accept`** puis `arch -arm64 swift test` redevient canonique.

NOT_TESTED (live) — chemin happy-path (on→off complet avec readback success) : **nécessite élévation root** (A14). Reboot-comportement `disablesleep` = UNDOCUMENTED → protocole Phase 4 (opérateur présent) ; le modèle fail-closed ADR 015 est correct dans les deux cas observés.

## G2b — Display mutation Swift (2026-09-14)

`DisplayMutator` protocol + `SLSDisplayMutator` (SkyLight via dlsym) + `DisplayMutationPolicy` (pure) + `DisplayMutationService` (orchestration) + `OwnedDisabledDisplays` (persistence atomique + cross-boot discard). CLI `disable <id>` / `enable <id>` / `restore --owned`. Logique unit-testée avec fakes ; chemin live happy-path = `BLOCKED_HARDWARE` (1 écran XDR).

```
$ arch -arm64 swift build   → Build complete, 0 warning
$ arch -arm64 swift test    → Executed 46 tests, with 0 failures   (9 Core + 6 Policy + 5 Lease + 6 Owned + 9 Service + 11 ViewModel)
$ runclosed disable 1       → exit 3 (refused: last active)
$ runclosed enable 1        → exit 5 (backend: kCGErrorCannotComplete — no-op sur 1 écran)
$ runclosed restore --owned → exit 0 (JSON stillOwned: [], owned record empty)
$ runclosed doctor          → JSON OK (unchangé)
$ runclosed displays        → JSON OK (unchangé)
```

Nouvelles régressions (21) :

`DisplayMutationPolicyTests` (6/6) :
```
testDisableAllowedOnMultiDisplayTopology ok
testDisableRefusedOnLastActiveDisplay    ok
testDisableRefusedOnStaleTargetNotInActiveSet ok
testDisableOnEmptyActiveSetAlwaysRefused ok
testEnableAllowsKnownTargets              ok
testEnableRefusesUnknownTargets          ok
```

`DisplayMutationServiceTests` (9/9, avec FakeDisplayMutator) :
```
testDisableRefusedOnLastActiveDisplay                 ok   # mutator jamais appelé
testDisableRefusedOnStaleTarget                       ok   # mutator jamais appelé
testDisableOnSuccessPersistsOwnership                 ok   # owned_displays.json écrit avec [2]
testDisableOnBackendFailureDoesNotPersistOwnership    ok   # record reste vide
testEnableRefusesUnknownTarget                        ok   # mutator jamais appelé
testEnableAcceptsOwnedTargetEvenIfNotCurrentlyActive  ok   # recovery path
testRestoreOwnedPersistsOnlyStillOwnedIDs             ok   # B3: rewrite depuis outcome
testRestoreOwnedClearsSuccessfullyReEnabledIDs        ok
testRestoreOwnedDiscardsStaleBootRecord               ok   # cross-boot discard
```

`OwnedDisabledDisplaysStoreTests` (6/6) :
```
testRoundTripPreservesIDs                  ok
testMissingFileReturnsEmptyRecord          ok
testCorruptFileReturnsEmptyRecord          ok   # B3: never assume ownership
testStaleBootRecordIsDiscarded             ok   # cross-boot discard
testAtomicWriteLeavesNoTempFile            ok
testRecordSchemaVersionIsCarried           ok
```

NOT_TESTED (live) — chemin happy-path disable 2e écran : `BLOCKED_HARDWARE` (1 écran). Le fake mutator couvre exactement les invariants B3 (rewrite depuis outcome, retain FAILED, cross-boot discard, last-active guard, stale-target guard, persistence conditionnée au succès).

## G2b-corrections — Pré-merge correctness fixes (2026-09-15, Phase 1, branche PR B)

Review externe (Ben, 2026-09-14) identifie 3 défauts dans G2b avant merge. Corrigés en Phase 1 sur la branche PR B (`agent/claude/20260915/runclosed-g2b-display`). Build clean, suite augmentée.

```
$ arch -arm64 swift build   → Build complete, 0 warning
$ arch -arm64 swift test    → Executed 50 tests, with 0 failures
                              (9 Core + 7 Lid Policy n/a + 5 Lease + 6 Owned Display
                               + 6 Owned Lid n/a + 9 Service Display + 9 Service Lid n/a
                               + 6 Display Policy + 11 ViewModel + 4 G2b-corrections)
$ runclosed restore --owned → exit 0, JSON {"restored":"all","stillOwned":[]} (machine Ben, 1 écran, record vide)
$ runclosed displays        → JSON OK (unchangé)
$ runclosed doctor          → JSON OK (inchangé)
$ runclosed status          → JSON OK (inchangé)
```

Note : G2b-corrections branche ne contient PAS G2c (lid stay-awake), donc les tests Lid (7 + 6 + 9 = 22) ne s'appliquent pas ici — ils sont dans PR C. PR B's scope = G2a + G2d-prep + G2b + Phase 1 corrections = 50 tests verts.

Nouvelles régressions (4) :

`DisplayMutationServiceTests` (4/4 ajoutés) :
```
testDisablePropagatesDeactivateAction                       ok    # disable → action == .deactivate (régression typo G2b)
testEnablePropagatesActivateAction                          ok    # enable → action == .activate (régression typo G2b)
testRestoreOwnedPropagatesActivateAction                    ok    # restore loop → chaque appel est un enable (pas disable)
testRestoreOwnedReturnsNonEmptyListOnPartial                ok    # service expose stillOwned non-vide → CLI mappe à exit 5
```

Tests existants **inchangés verts** (les 9 + 6 + 6 d'avant G2c + les 21 de G2b = 42 anciens + 4 nouveaux = 46 attendus ; plus 4 ViewModel supplémentaires = 50).

NOT_TESTED (live) — chemin exit 5 du CLI sur machine Ben : impossible en live (1 écran, `restore --owned` ne peut jamais être partiel puisque `OwnedDisabledDisplays` est vide). La logique est couverte par `testRestoreOwnedReturnsNonEmptyListOnPartial` qui exerce le contrat service-level dont le CLI dépend ; le mapping `stillOwned.isEmpty ? 0 : 5` est trivialement testable par lecture du code.

Defect ledger :
- `[DEFECT:action-typo-displaymutation]` (where: `DisplayMutation.swift:62,73,85,96,113` — fix ADR 014) — résolu Phase 1
- `[DEFECT:cli-exit-code-partial-restore]` (where: `main.swift:255` — fix ADR 014) — résolu Phase 1
- `[DEFECT:doc-drift-restore-owned-stub]` (where: `PROGRESS.md:84` omnibus — fix ADR 014) — résolu sur PR omnibus, propagé ici via §G3 cross-référence

## A14 — Helper LaunchDaemon, tranche 1 registration/status SANS XPC (2026-09-16, branche dédiée)

`RunClosedHelperSupport` (descriptor + DaemonStatus 1:1 SMAppService + DaemonRegistrar seam + HelperLifecycleService au rapport honnête) + `RunClosedHelper` daemon (start/log/SIGTERM, zéro opération privilégiée) + plist sans MachServices (volontaire). ADR 016 : SMAppService.daemon, PAS SMJobBless ni AuthorizationExecuteWithPrivileges (deprecated) ; API root bornée `setDisableSleep(Bool)` + health/version ; ad-hoc interdit.

```
$ build (workaround Xcode 27, frontend direct + SDKROOT)   → Build complete! (0 warning)
$ xctest (workaround arch -arm64 + frameworks rpaths):
  RunClosedHelperSupportTests  Executed 6 tests,  0 failures   # ADR 016 contract
  RunClosedCoreTests           Executed 9 tests,  0 failures
  RunClosedAppTests            Executed 11 tests, 0 failures
  RunClosedPersistenceTests    Executed 5 tests,  0 failures
  → 31/31 verts
```

Nouvelles régressions (`HelperLifecycleTests`, FakeRegistrar — 6/6) :
```
testRequiresApprovalIsSurfacedNotSwallowed      ok  # état attendu, jamais avalé/normalisé
testNotFoundIsDistinctFromNotRegistered         ok  # bundle cassé ≠ clean slate
testRegisterOnlyFromNotRegistered               ok  # pas de re-registration
testRegisterAndReportNormalPathLeadsToRequiresApproval  ok  # porte approbation utilisateur = chemin normal
testReportIsHonestAboutBoundedOperationAndXPC   ok  # bounded-op exacte + xpcImplemented:false en clair
testDescriptorIdentityIsStable                  ok  # plist/binary/label = points fixes partagés
```

NOT_TESTED (live) → **voir §A14-T1 (2026-09-17)** : la registration réelle est désormais QUALIFIÉE en E2E ; restent l'approbation humaine Login Items → `enabled`, XPC (tranche 2), setDisableSleep root (tranche 2).

## A14-T1 — packaging + BundleProgram + E2E registration réelle (2026-09-17, branche dédiée)

Correctifs de la deep review : plist `Program` absolu → `BundleProgram` relatif (spec Apple « make the path relative to the bundle ») ; contradictions `KeepAlive`/`RunAtLoad` retirées (le daemon ne tourne pas en T1) ; script d'assemblage du vrai `.app` ; deep link d'approbation exposé (`openLoginItemsSettings()`) + CLI `runclosed helper …` ; sémantique OS mesurée + codée (ADR 017/018). Build + tests :

```
$ arch -arm64 swift build   → Build complete! (0 warning)
$ arch -arm64 swift test    → 38/38 (9 Core + 11 App + 5 Persistence + 13 Helper)
$ bash scripts/build-runclosed-app.sh SIGN_IDENTITY="Developer ID Application: YOYAKU (YZYJJPX484)"
   → RunClosed.app assemblé + signé + `codesign --verify --strict` OK
```

E2E réel sur le .app signé installé dans /Applications (macOS 26.6, machine Ben) :

```
$ runclosed-cli helper status     → {"status":"notRegistered"}                 exit 0
$ runclosed-cli helper register   → {"lastOperationSucceeded":true,
                                     "status":"requiresApproval"}              exit 0
$ runclosed-cli helper status     → {"status":"requiresApproval"}              exit 0
$ runclosed-cli helper unregister → {"lastOperationSucceeded":true,
                                     "status":"notRegistered"}                 exit 0
$ runclosed-cli helper status     → {"status":"notRegistered"}                 exit 0
$ codesign -dv app     → Identifier=com.benjaminbelaga.RunClosed · TeamIdentifier=YZYJJPX484
$ codesign -dv daemon  → Identifier=runclosed-privileged-helper  · TeamIdentifier=YZYJJPX484
$ pgrep runclosed-privileged-helper → aucun process (daemon jamais lancé : aucun trigger/MachServices)
```

pmset : RunClosed n'a émis **aucun pmset** (aucun appel dans les binaires de cette tranche). Le `SleepDisabled=1` observé pendant l'E2E est tenu par l'app quotidienne **DisableScreen** (PID 57018, `~/DisableScreen/disablescreen.log` : « lid stay-awake desired=True rc=0 observed=True », 2026-09-16 21:21) — antérieur de ~17h et indépendant de l'E2E ; non touché.

Découvertes E2E (corrigées + documentées ADR 018) :
- **Collision de casse APFS** : `runclosed` et `RunClosed` sont le MÊME fichier (l'app était écrasée par le CLI) → CLI embarqué renommé `runclosed-cli`.
- **macOS 26 — état frais = `notFound`** (pas `notRegistered`) : `registerAndReport()` tente depuis les deux, sinon une machine fraîche ne registrerait jamais.
- **macOS 26 — `register()` peut THROW "Operation not permitted" (code 1) tout en passant à `requiresApproval`** : pending = succès (le throw seul aurait produit un faux échec CLI).
- `unregister()` depuis `requiresApproval` → `notRegistered` : teardown propre vérifié.

Nouvelles régressions (+2) : `testRegisterProceedsFromNotFound` · `testRegisterNoopWhenRequiresApproval`.

NOT_TESTED (live, restant) : approbation humaine Login Items → `enabled` (geste opérateur) · XPC (A14-T2) · setDisableSleep live.

## G2d — Popup UI à toggles (2026-09-20, branche `g2d-popup-toggles`)

Parité fonctionnelle avec le panneau Python DisableScreen : NSPanel + NSSwitch par écran, slider luminosité, sélecteur résolution, switch capot, switch login item, leases, Quit.

**Défaut racine trouvé et corrigé en cours de route** — `PowerReadback` splittait la ligne `pmset -g` sur l'espace littéral alors que `pmset` sépare par TABULATION :
```
$ pmset -g | grep SleepDisabled | cat -v
 SleepDisabled^I^I1
```
Le readback retournait `false` sur un flag réellement à `1` → chaque toggle capot était rapporté « backend failed » alors que le write avait réussi (et l'ownership n'était pas enregistré). Fix : split whitespace-run + retry borné (5×150ms) pour la latence de propagation du flag noyau.

**Tests** (suite globale 295 exécutions uniques, 0 failure) — nouveaux :
```
DisplayModeSelectionTests (8)      ok  # dedupe géométrie/fréquence, tri, label, best, index
PowerReadbackTests (6)             ok  # tabs réels, espaces, clé absente=unknown, vide
LidMutationServiceTests (15)       ok  # inchangés, contrat B1/B2/ADR015
```

**Preuve live UI (cliclick, app installée `/Applications`, 2026-09-20)** :
```
$ pmset -g | grep SleepDisabled      → 0
$ <clic toggle capot dans le popup>  → 1   + status: observed "on", ownedByThisBoot true
$ <re-clic toggle>                   → 0   + status: observed "off", ownedByThisBoot false
$ <capture écran>                    → slider 100%, résolution 3456x2234 @120Hz,
                                       switch écran grisé (dernier écran), capot + login item présents
```

**Cutover** — app Python : `--unregister` (login item), arrêtée, retirée de `/Applications` (zip + `.retired` réversibles) ; alias Desktop → `/Applications/RunClosed.app` ; login item `RunClosed` enregistré (`requiresApproval` — approbation Ben).

NOT_TESTED — chemin 2 écrans (BLOCKED_HARDWARE), approbation Login Items (geste Ben), reboot `disablesleep` (ADR 015 Phase 4).

## G5b — doctor truthfulness : fin de la contradiction qualification capot (2026-09-20)

Défaut détecté pendant la mission notarisation (G5, `PROGRESS.md §G5`) : `doctor` affirmait `lid.backend="unqualified"` (chaîne hardcodée en G2, jamais mise à jour) alors que `docs/compatibility/README.md` enregistre le chemin capot **PASS** depuis la qualification live du 2026-09-20. Fix ADR 020 : deux faits distincts, plus aucune chaîne globale.

```
$ build/RunClosed.app/Contents/MacOS/runclosed-cli doctor --json
  "lid" : {
    "backend" : "sudo -n /usr/bin/pmset -a disablesleep (app toggle)",
    "qualification" : "closed-lid keep-awake qualified live 2026-09-20 (docs/compatibility/README.md; needs the passwordless sudoers drop-in — README)",
    "runLid" : "not implemented — `run --lid` exits 3 (ADR 007)"
  },
  "lidStayAwake" : "on", "displays" : 1,
  "idleAssertion" : { "backend" : "IOPMAssertionCreateWithName", "capability" : "supported" }

$ runclosed-cli run --lid -- true
  stderr: "run --lid refused: the CLI lid wrapper is not implemented (ADR 007); the qualified
           closed-lid keep-awake path is the menu-bar app toggle. Use --idle-only for
           idle-sleep prevention."                                   → exit 3

$ runclosed-cli run --idle-only -- sh -c 'exit 7'                    → exit 7 (non-régression)

$ arch -arm64 swift test  → 5 bundles verts, 0 failure (exit 0)
```

Sonde « règle sudoers présente ? » évaluée puis **rejetée** : `sudo -n -l <cmd>` sort 0 même sans NOPASSWD (mesuré : `sudo -n -l /usr/bin/true` → rc 0) — elle ne discrimine pas, et un probe fragile aurait remplacé une affirmation périmée par une affirmation non fiable (ADR 020).

## ADR 022 — garde batterie faible (2026-10-15)

Aucune mutation réelle : ni `pmset -a disablesleep`, ni `pmset sleepnow` n'ont été exécutés. Le chemin d'action est couvert par des faux backends (`FakeLid` + `FakeSleeper`), avec des relevés injectés et des stores en fichiers temporaires.

```
$ arch -arm64 swift test            # Swift 6.3.3, macOS 26.6, M5 Max
RunClosedPersistenceTests.xctest   22 tests, 0 failures   (+3 LowBatteryLatchStoreTests)
RunClosedMacSystemTests.xctest     62 tests, 0 failures   (+12 BatteryReadbackTests, +12 LowBatteryGuardServiceTests)
RunClosedHelperSupportTests.xctest 13 tests, 0 failures
RunClosedCoreTests.xctest          57 tests, 0 failures   (+27 LowBatteryPolicyTests)
RunClosedAppTests.xctest           11 tests, 0 failures
→ 165/165 (111 avant ADR 022), 0 warning

# après corrections de la revue ai-review-gate (verrou LidWriteLock, sleep unique sur échec, décodage tolérant)
RunClosedPersistenceTests 24 · RunClosedMacSystemTests 63 · HelperSupport 13 · Core 57 · App 11
→ 168/168, 0 warning

# après la 2e revue (alerte « non protégé », refus notifié une fois, tryWithLock non bloquant)
RunClosedPersistenceTests 24 · RunClosedMacSystemTests 65 · HelperSupport 13 · Core 58 · App 11
→ 171/171, 0 warning

# après la 3e revue (OFF opérateur no-op annule le réarmement, verrou persisté avant sleepnow)
RunClosedPersistenceTests 24 · RunClosedMacSystemTests 67 · HelperSupport 13 · Core 58 · App 11
→ 173/173, 0 warning

# après la 4e revue (réarmement retenu si le secteur se décharge)
RunClosedPersistenceTests 24 · RunClosedMacSystemTests 69 · HelperSupport 13 · Core 60 · App 11
→ 177/177, 0 warning

$ runclosed low-battery status      # relevé réel ~01:15
  battery {onBattery:false, chargePercent:9, isCharging:true, currentMilliamps:-444}
  input.acDraining: true → decision none/onAC (aucun réarmement dû)
$ runclosed low-battery simulate ac 40 0 --lid off --released --ac-draining → none / rearmHeldACDraining
```

Contrats verrouillés par les tests :
- Seuils : 20 % → `warn`, 21 % → rien, 10 % → `releaseAndSleep`, 11 % → `warn`, 15 % + 10 min → critique, 15 % + 11 min → `warn`, 80 % + 3 min → rien (estimation bruitée).
- Secteur à 1/5/10/20 % → jamais d'action ; source inconnue ou charge inconnue → jamais d'action.
- B2 : record périmé ou flag posé par un autre outil → `warn`, 0 appel au backend, 0 veille. Flag illisible → `warn` (B1). Flag OFF → rien.
- Anti-flap : alerte unique par épisode, réinitialisée seulement sur secteur > 20 %. Après relâchement, aucune seconde veille.
- Hystérésis : secteur à 12 % et 15 % → maintenu ; 16 % → `rearm` vérifié, propriété reprise. Sur batterie à 90 % → pas de réarmement. Échec du réarmement → verrou conservé pour le tick suivant. Commande opérateur → dette effacée.
- Revue : un relâchement qui échoue en boucle ne relance la veille qu'une fois par épisode, réinitialisé sur secteur > 20 %. Un fichier de verrou antérieur, sans la nouvelle clé, garde `releasedByGuard`. `LidWriteLock` : 8 sections concurrentes, au plus une à l'intérieur.
- `evaluate()` (chemin de `status`) : 0 mutation, 0 écriture de verrou. Échec backend sur un flag possédé → veille tentée, verrou de relâchement non posé.
- Parseur IOKit : batterie, secteur, `Time to Empty` à -1/0/absent → inconnu, capacité brute en mAh → %, `NSNumber`, max à 0, état « Off Line » → inconnu (jamais « secteur »), desktop sans batterie, relevé live sans crash.

CLI (binaire debug puis CLI embarquée dans le bundle assemblé), en lecture seule :
```
$ runclosed low-battery status
  battery {onBattery:false, chargePercent:14, isCharging:true, minutesRemaining:null}
  input {lidFlag:"off", ownership:"notOwned"} → decision {action:"none", level:"ac", reason:"onAC"}
  guardEnabled:true ; aucun fichier low_battery_guard.json créé (status n'écrit rien)
$ runclosed low-battery simulate true 9 8                         → releaseAndSleep / criticalOwned
$ runclosed low-battery simulate battery 9 8 --ownership stale    → warn / criticalStaleOwnership
$ runclosed low-battery simulate battery 9 8 --ownership not-owned→ warn / criticalNotOwned
$ runclosed low-battery simulate false 9 8                        → none / onAC
$ runclosed low-battery simulate true 20 unknown                  → warn / lowBattery
$ runclosed low-battery simulate ac 16 0 --lid off --released     → rearm / rearmAfterRecovery
$ runclosed low-battery simulate ac 15 0 --lid off --released     → none / rearmHeldBelowThreshold
$ runclosed low-battery simulate true 80 3                        → none / chargeOK
$ runclosed low-battery simulate true 15 10                       → releaseAndSleep / criticalOwned
$ runclosed low-battery simulate true 5 2 --lid unknown           → warn / lidFlagUnknown
$ runclosed low-battery simulate maybe 9 8                        → usage, exit 64
$ scripts/hardware/low-battery-qualification.sh                   → BLOCKED_HARDWARE, exit 3 (sans opt-in)
```

NB : dans le plan de mission, l'exemple `simulate false 9 8` suppose un premier argument « sur secteur ? ». Le contrat retenu est `<onBattery>`, donc l'incident se rejoue avec `simulate true 9 8` (ou `battery 9 8`). Avec `false`, la garde ne fait rien sur secteur, ce qui est le comportement voulu.

Bundle : `scripts/build-runclosed-app.sh` (ad-hoc, `OUT_DIR` hors du dépôt), `codesign --verify --strict` OK, 3 binaires et les deux lproj présents. Défaut trouvé sur le bundle : `UserDefaults(suiteName: "com.benjaminbelaga.RunClosed")` lancé depuis le bundle de même identifiant renvoie « does not make sense and will not work ». Corrigé : le domaine standard est lu quand la suite est le bundle principal.

État machine observé au début de la mission (lecture seule, 2026-10-15 ~00:45) : `SleepDisabled 1`, `owned_lid.json` d'un boot précédent, donc `recoveryPending: true`. Avec ADR 022, cet état donne `criticalStaleOwnership`, soit une alerte sans relâchement (décision ouverte, voir ADR 022). Vers 00:58, sur secteur 100 W : 10 % avec `InstantAmperage` -194 mA, soit une décharge sur secteur. Ce cas relève de la sonde Guardian `ac-draining`, pas de cette garde.

## ADR 022 — propriété d'urgence d'un record périmé (2026-10-15, décidée par l'orchestrateur)

Build et tests lancés une seule fois, en `nice -n 19`, après le retour d'un courant de charge positif (pause pendant la décharge sur secteur). Aucune mutation réelle.

```
$ nice -n 19 arch -arm64 swift test
RunClosedPersistenceTests 25 · RunClosedMacSystemTests 74 · HelperSupport 13 · Core 63 · App 11
→ 186/186, 0 warning
```
Nouveaux contrats :
- Record périmé à ≤ 10 % sur batterie, ou ≤ 10 min dans la bande des 20 % → `releaseAndSleep` / `emergencyStaleOwnership`.
- Record périmé sur secteur → rien. Record périmé à 15 % → alerte seulement (la règle d'urgence ne vaut que dans la branche critique).
- Aucun record (`notOwned`) → `warn` / `criticalNotOwned`, 0 mutation, 0 ligne d'audit.
- Service : relâchement d'urgence vérifié, 1 veille. Le record est remplacé par l'OFF du boot courant. 1 ligne d'audit (`reason=emergencyStaleOwnership`, `recordBootID=OLD`, `bootID=A`) écrite avant la veille.
- `LidMutationService` : `.lowBatteryEmergency` autorisé sur notre record périmé, refusé sans record (`notOwned`). `.automatic` toujours refusé sur un record périmé (B2 inchangé).
- L'opérateur garde la main : un clic pendant un tick reçoit `busy` (`tryWithLock` renvoie nil), et un OFF opérateur après un relâchement d'urgence annule le réarmement.
- Journal d'audit : ajout de lignes entières, relecture dans l'ordre.

CLI (lecture seule) :
```
$ runclosed low-battery status   → lidRecord {ownedBootID, ownedByThisBoot, recoveryPending}, protection, remedy
  (état actuel : flag off → "not-needed", remedy null ; aucun fichier créé)
$ runclosed low-battery simulate battery 9 8 --ownership stale      → releaseAndSleep / emergencyStaleOwnership | armed (emergency)
$ runclosed low-battery simulate ac 5 3 --ownership stale           → none / onAC
$ runclosed low-battery simulate battery 9 8 --ownership not-owned  → warn / criticalNotOwned | unprotected
$ runclosed low-battery simulate battery 18 unknown --ownership stale → warn / lowBattery
```
Preuve live (orchestrateur, 2026-10-15) : record 8C8825C7, boot A6CB8DFE, `recoveryPending: true`. Relâchement opérateur effectué, SleepDisabled 0 vérifié. Batterie à 9 % **sur secteur**.

## ADR 023 — session de maintien éveillé minutée (2026-11-06)

Aucune mutation du vrai flag d'alimentation : tous les chemins d'écriture sont couverts par des fakes. `session start` n'a pas été lancé sur la machine (il aurait flippé `disablesleep`) ; seules les surfaces en lecture seule et les codes d'usage ont été exercés sur le binaire.

```
$ arch -arm64 swift build --build-tests
Build complete! (0 warning)

$ arch -arm64 swift test
RunClosedPersistenceTests  46 · RunClosedMacSystemTests 153 · HelperSupport 13
RunClosedCoreTests        106 · RunClosedAppTests        11
→ 329/329, 0 échec
```

Dont **143 nouveaux** : 43 `SessionPolicyTests`, 13 `SessionStoreTests`, 8 `AppLivenessLockTests`, 50 `SessionServiceTests`, 24 `SessionGuardTickTests`, 5 dans `LidMutationServiceTests` (initiateur `.sessionRecovery`).

Relecture, tour 1 (11 tests ajoutés) :
- Quit pendant une session mise en pause par la garde batterie : la dette de réarmement est effacée, une étape batterie suivante sur secteur à 80 % ne réarme pas. Sans session, le quit laisse la dette intacte (ADR 022 inchangé).
- Plafond de 7 jours au démarrage et à l'extension ; durées infinies ou NaN refusées ; conversion secondes → nanosecondes et addition sur le compteur continu saturées, jamais de trap.

Relecture, tour 2 (`ai-review-gate`, 0 CRITICAL, 5 WARN corrigés, 7 tests ajoutés) :
- Extension d'une session en pause batterie : la pause reste, l'échéance bouge.
- Interrupteur simple après un reboot : réarmé comme en ADR 022 ; session minutée d'un autre boot : dette annulée une fois, aucun refus répété au tick suivant.
- `session.json` impossible à écrire : aucun appel `pmset` ; démarrage raté : la session échue remplacée est restaurée.
- Non couverts par un test unitaire (code AppKit) : lecture `pmset` retirée du thread principal (cache rafraîchi hors thread), hauteur de la ligne capot avec « +30 min » / « End », titres des boutons tirés des préréglages, état « En pause » visible dans la ligne et la barre.

```
$ runclosed-cli session start --for 999999999999h   → exit 64 « a session is capped at 7 days »
$ runclosed-cli session start --for inf             → exit 64 (usage)
$ runclosed-cli session extend 8d                   → exit 64 (usage)
$ runclosed-cli definitely-not-a-command            → exit 64
```

Relecture, tour 3 (`ai-review-gate`, 0 CRITICAL, 3 WARN corrigés, 10 tests ajoutés) :
- Quit avec l'interrupteur simple (session indéfinie) mis en pause par la garde : record effacé, dette de réarmement conservée (ADR 022) ; record illisible au quit : record et dette effacés.
- Interrupteur rallumé sur une session minutée en pause : même id, même échéance, pause levée ; session due, d'un autre boot, indéfinie ou absente : nouvelle session indéfinie.
- `pausedReason` inconnu (`"thermal"`) : la session se charge, reste en pause, garde son échéance.
- `save()` dans un dossier absent : `false`, aucun dossier créé.
- Arguments de `session start` (fonction pure, sans binaire) : `--for` + `--indefinite` dans les deux ordres → usage ; aucun argument, valeur manquante ou illisible, option inconnue → usage ; `--for 200h` → plafond.
- `session start --for … --indefinite` n'a pas été lancé sur la machine : un binaire périmé aurait démarré une session réelle. Le refus est couvert par le test pur ci-dessus.

Relecture, tour 4 (`ai-review-gate`, 0 CRITICAL, 5 WARN corrigés, 12 tests ajoutés) :
- Pause batterie levée quand l'opérateur rallume le flag lui-même, ou quand le réarmement le trouve déjà ON ; pause conservée tant que le flag reste OFF.
- End sur une session indéfinie adoptée par-dessus un flag posé par un autre outil : flag éteint, record effacé. End sur une session minutée : flag d'un autre outil laissé intact, aucun appel `pmset`.
- Démarrage réussi : dette de réarmement effacée ; démarrage raté : dette conservée.
- `app.lock` : libre sans détenteur, tenu tant que l'app le tient (sonde depuis un autre descripteur, même processus), libéré quand le détenteur disparaît, second détenteur refusé, fichier impossible à ouvrir = non tenu.
- `testTheLockIsExclusiveForTheWholeTick` sonde le verrou depuis l'étape session et l'étape batterie pendant `tick()`. Contre-épreuve : avec `tick()` modifié pour ne plus prendre le verrou, le test échoue sur les deux étapes (« locked during the session step », « locked during the battery step ») ; le code a été restauré ensuite.
- `testTickDoesNotNestTheWriteLock` tourne sur son propre thread avec un délai de 10 s : un emboîtement devient un échec nommé, plus un job CI bloqué.

Relecture, tour 5 (`ai-review-gate`, 0 CRITICAL, 3 WARN corrigés, 12 tests ajoutés) :
- Session en cours sur un flag qui se lit OFF (crash entre le journal et le flag) : effacée au tick, aucun appel `pmset` ; flag INCONNU ou ON : session laissée ; session indéfinie : record seul effacé ; session en pause : jamais touchée.
- Pause batterie perdue (flag OFF, dette de réarmement en attente) : pause restaurée, dette conservée.
- Étape session seule sous `LidWriteLock` (garde batterie coupée) : une session due est terminée, flag OFF vérifié, record effacé ; une session due est expirée avant toute réconciliation.
- `app.lock` : `hold()` échoue pendant qu'une sonde le tient, réussit au réessai une fois la sonde partie.
- Extension d'une session d'un autre boot : même `bootID`, échéance continue retirée, échéance murale déplacée ; même boot : échéance continue déplacée.
- Titre de barre compact : `3h`, `1h41`, `1h05`, `45m`, `<1m`, rien pour une session indéfinie.
- `testTickDoesNotNestTheWriteLock` vérifie le résultat de l'attente avant de lire celui du thread.
- Non couverts par un test unitaire (code AppKit) : réessai de `app.lock` à chaque tick, `runSessionOnlyTick`, cache de propriété lu hors thread principal.

```
$ runclosed-cli session status --json        → exit 0, ownership ownedThisBoot, session.present false
$ runclosed-cli session start --for 200h      → exit 64 « a session is capped at 7 days »
$ runclosed-cli session start --for 2h --indefinite → exit 64 (usage)
$ runclosed-cli session bogus                 → exit 64
$ runclosed-cli definitely-not-a-command      → exit 64
```

Relecture, tour 6 (`ai-review-gate`, 0 CRITICAL, 3 WARN corrigés, 6 tests ajoutés) :
- Démarrage dont `pmset` a rendu 0 et déplacé le flag mais dont la relecture a échoué : échec signalé, flag remis à OFF (`[true, false]`), record retiré.
- Démarrage dont la relecture est devenue INCONNUE : une seule écriture, record gardé ; il part dès que le flag se lit OFF.
- Session indéfinie en pause sans réarmement dû : effacée, et un démarrage minuté n'est plus refusé.
- Au tick : pause gardée tant que le réarmement est dû (sur secteur sous le seuil) ; pause dont le réarmement a été annulé : effacée, flag laissé OFF.
- `app.lock` : une sonde en cours (verrou partagé) ne fait pas croire à l'app ; `release()` rend le verrou avant la fin du détenteur, idempotent, le verrou se reprend ensuite.
- Non couverts par un test unitaire (code AppKit) : `release()` dans la section verrouillée du teardown, redessin du compte à rebours après Start, +30 min et End.

Relecture, tour 7 (`ai-review-gate`, 0 CRITICAL, 3 WARN corrigés, 5 tests ajoutés, 4 attentes corrigées) :
- Les bancs `SessionServiceTests` et `SessionGuardTickTests` passent par le vrai `LidMutationService` (`SessionService.gatedLid`, le câblage même de `live()`) au lieu d'une copie du contrôle. La copie vérifiait la propriété avant de lire le flag : 4 tests attendaient `flagNotOwned` sur un flag OFF, le vrai service rend `flagAlreadyOff`. Attentes corrigées.
- Record de propriété perdu pendant une session minutée : à l'échéance, `.ended(.flagLeftOn)`, flag laissé ON (B2), record et dette de réarmement effacés, `stopsKeepingAwake` faux.
- Refus relu : flag relu OFF → `flagNotOwned` ; relu INCONNU → `flagLeftOn`.
- Démarrage abandonné dont l'annulation échoue aussi : record gardé, puis `flagLeftOn` à l'échéance au lieu d'une fin silencieuse.
- Au tick : `flagLeftOn` n'est pas une fin normale (`sessionEndedNaturally` faux) ; une écriture en échec rend `.retained("sudo: a password is required")` et garde le record.
- End sur une session minutée dont le flag est étranger : `.flagLeftOn`, flag intact, record effacé.
- Non couverts par un test unitaire : refus de `session extend` quand l'app ne tourne pas (câblage CLI sous `LidWriteLock`, lecture du code), notification et message du popup pour `flagLeftOn` (AppKit).
Relecture, tour 8 (`ai-review-gate`, 0 CRITICAL, 1 WARN corrigé, 2 tests ajoutés) :
- Quit dont le flag ne se lit pas OFF : `finishOnQuit` garde la session et la rend ; quit qui termine la session ou sans session : rien à signaler.
- Durées : `2h3h`, `1h1h1h`, `30m2h`, `5s1m`, `1h30m30m`, `30s5` refusées ; `1h30m15s` = 5415 s, `1m30` = 90 s.
- Le test du plafond affirme que `999999999999h` se lit puis est refusé (`overCap`), sans branche conditionnelle.
- Non couverts par un test unitaire (AppKit) : la notification de quit avant la sortie, le cache de session rempli hors du thread principal.

Relecture, tour 9 (`ai-review-gate`, 0 CRITICAL, 2 WARN corrigés, 2 tests ajoutés, 1 test adapté) :
- End sans opérateur sur une session indéfinie qui a adopté un flag étranger : `.flagLeftOn`, flag ON, aucune écriture. End sans opérateur sur une session indéfinie dont le flag est nôtre : `.released`, flag OFF, record effacé. End opérateur (`byOperator: true`) : flag adopté éteint, comme avant.
- CLI sur le bundle : `session end --bogus` → 64, `session end --operator extra` → 64, `session end` sans session → 3.
- Non couvert par un test unitaire (AppKit) : l'activité anti-App Nap limitée aux sessions minutées en cours, sans effet sur la veille.

Contrats verrouillés :
- Échéance continue sur le même boot ; une veille de 6 h dans une session de 1 h rend la session due (ce que `systemUptime` manquerait) ; non due avant l'échéance ; `remaining` à 0 une fois due.
- Échéance murale inter-boot ; le compteur continu d'un boot précédent est ignoré et ne peut pas terminer la session immédiatement (comparaison naïve sinon).
- Session indéfinie jamais due, jamais de libellé de temps restant, jamais extensible.
- Refus de démarrer une session minutée quand le flag est observé ON et que l'ownership est `notOwned` ou `staleRecord` ; démarrage indéfini non bloqué (ADR 021 gouverne déjà ce cas) ; refus d'une seconde session ; une session déjà due est remplacée ; durée nulle ou négative refusée.
- Extension depuis maintenant (pas depuis l'ancienne échéance) ; elle ranime une session due et garde une pause batterie (seul le réarmement de la garde la lève) ; no-op sur une session indéfinie et sur un pas négatif.
- Pause/reprise : l'échéance et l'identité ne bougent pas.
- `allowsRearm` : vrai pour une session vivante du même boot, faux si due ou d'un autre boot, vrai s'il n'y a aucune session (ADR 022 intact).
- Libellés : `2 h 41 left`, `8 min left`, `1 h left`, `< 1 min left` ; `Until … · …` avec fuseau et locale injectés.
- Parsing des durées : `2h`, `90m`, `1h30m`, `1h30`, `45` (= 45 min), `30s`, insensible à la casse ; `""`, `abc`, `2x`, `h`, `0`, `-5m` refusés.
- Persistance : round-trip (dont pause et session indéfinie), `clear()` idempotent, fichier absent, quatre formes de fichier corrompu → aucune session, `load()` ne réécrit rien, `schemaVersion` rapporté, schéma futur décodé, forme nue acceptée, dates ISO-8601 lisibles en JSON, chemin canonique sous Application Support.
- Service : le record est écrit avant le flag et supprimé si le flag échoue ; adoption d'un flag déjà ON possédé sans seconde écriture ; refus sans mutation ni journal ; expiration vérifiée → record effacé ; `notOwned` → effacé sans écriture ; échec backend → record conservé ; aucune session → no-op ; indéfinie jamais expirée ; End ; End et expiration effacent la dette de réarmement ; extension sans écriture du flag ; pause/reprise ; `allowsRearm`.
- `sessionRecovery` : relâche notre record du boot de la session ; refuse un record d'un autre boot, l'absence de record, un record qui ne réclame plus l'ownership ; B1 reste bloquant. `releaseInitiator` = `.automatic` sur le boot de la session, `.sessionRecovery` sinon.
- Tick partagé : **régression — le tick n'emboîte jamais `LidWriteLock`** (s'il emboîtait, `withLock` ouvrirait un second fd et le test se bloquerait) ; la section est exclusive de bout en bout ; expiration + effacement ; `notOwned` sans mutation ; relâchement batterie → pause (échéance conservée) puis réarmement → reprise ; réarmement retenu quand la session est due ; End annule la dette à travers le tick ; sans session, ADR 022 identique (relâchement + veille + verrou, puis réarmement).

Bundle et CLI (binaire embarqué, lecture seule) :
```
$ bash scripts/build-runclosed-app.sh            → OK: build/RunClosed.app (ad-hoc, runtime)
$ codesign --verify --strict build/RunClosed.app → exit 0
$ runclosed-cli session status --json
  ownership: "ownedThisBoot" ; observed: "on" ; session { present: false } ; rowLabel: null
$ runclosed-cli session end                      → « refused: no session is running », exit 3
$ runclosed-cli session extend 30m               → « refused: no session is running », exit 3
$ runclosed-cli session extend 9999h             → exit 64
$ runclosed-cli session start --for 2h3h         → usage, exit 64
$ runclosed-cli session start --for nonsense     → usage, exit 64
$ runclosed-cli session bogus                    → usage, exit 64
$ runclosed-cli definitely-not-a-command         → « unknown command », exit 64
```

NOT_TESTED (matériel) : expiration réelle après une nuit capot fermé, tick au réveil, notifications macOS, rendu du popup et du titre de barre sur la build installée. Aucune de ces mesures n'a été faite ; rien n'est supposé.

## ADR 024 — filet de secours launchd (2026-11-07, branche `agent/claude/20261106/2ad8bd6d-e42-runclosed-backstop`)

Tout ce qui suit a réellement été exécuté dans ce worktree. Aucun `recover --backstop`, `backstop register`,
`session start` ni `lid-stay-awake on|off` n'a été lancé contre la machine réelle : les chemins de mutation sont
couverts par des fakes.

Build et suite complète :

```
$ arch -arm64 swift build --build-tests
  Build complete, 0 error, 0 warning
$ arch -arm64 swift test
  RunClosedCoreTests           124 tests, 0 failures
  RunClosedMacSystemTests      183 tests, 0 failures
  RunClosedPersistenceTests     46 tests, 0 failures
  RunClosedHelperSupportTests   27 tests, 0 failures
  RunClosedAppTests             11 tests, 0 failures
  → 391 tests, 0 failures (329 avant ce lot : +62)
```

Suites ajoutées ou étendues, exécutées séparément :

```
$ arch -arm64 swift test --filter RunClosedCoreTests.SessionPolicyTests               → 45 tests, 0 failures (43 + 2)
$ arch -arm64 swift test --filter RunClosedCoreTests.RecoveryPolicyTests              → 24 tests, 0 failures (16 au tour 1, +7 `runFreshness`)
$ arch -arm64 swift test --filter RunClosedMacSystemTests.SessionGuardTickTests        → 26 tests, 0 failures (24 + 2)
$ arch -arm64 swift test --filter RunClosedMacSystemTests.RecoveryBackstopServiceTests → 31 tests, 0 failures (20 au tour 1)
$ arch -arm64 swift test --filter RunClosedMacSystemTests.RecoverCommandTests          → 13 tests, 0 failures (8 au tour 1)
$ arch -arm64 swift test --filter RunClosedPersistenceTests.BackstopHeartbeatStoreTests→  7 tests, 0 failures
$ arch -arm64 swift test --filter RunClosedHelperSupportTests.BackstopRegistrationTests→ 14 tests, 0 failures
```

Bundle et CLI (binaire embarqué) :

```
$ bash scripts/build-runclosed-app.sh
  → OK: build/RunClosed.app (ad-hoc, runtime)
  → Contents/Library/LaunchAgents/com.benjaminbelaga.runclosed.backstop.plist présent
$ codesign --verify --strict build/RunClosed.app                         → exit 0
$ plutil -lint build/RunClosed.app/Contents/Library/LaunchAgents/*.plist → OK
$ build/RunClosed.app/Contents/MacOS/runclosed-cli backstop status --json
  backstop { status: "notFound", protecting: false, intervalSeconds: 60 }
  plistName: "com.benjaminbelaga.runclosed.backstop.plist"
  programArguments: ["runclosed-cli", "recover", "--backstop"]           (exit 0)
$ build/RunClosed.app/Contents/MacOS/runclosed-cli recover --bogus       → exit 64
```

`notFound` est l'état honnête d'un agent jamais enregistré sur cette machine (ADR 018). Rien n'a été enregistré :
ni `backstop register`, ni le lancement de l'app installée.

Contrats verrouillés par les tests :

- **Politique pure** : sortie rapide (aucun record ne revendique le flag ET aucune session) ; un record relâché ne
  revendique rien ; un record nôtre sans session, ou d'un boot précédent, demande quand même le travail ; une session
  seule aussi ; échéance due / non due / indéfinie jamais due ; batterie critique avec flag nôtre (relâche), étranger
  (B2, jamais muté), record périmé (urgence), bon niveau (rien), flag illisible (`lidFlagUnknown`) ;
  **dette de réarmement retenue, jamais exécutée** ; un balayage de la grille complète (flag × pourcentage × source ×
  ownership × latch) prouve qu'aucune combinaison ne demande un `enable`.
- **Service backstop sur fakes** : rien à faire ⇒ 0 sans aucun appel système (ni `pmset`, ni relevé batterie, ni
  `sleepnow`) ; app vivante ⇒ 0, aucune mutation, aucun verrou laissé ; verrou tenu ⇒ 75, aucune mutation, aucune
  ligne d'audit, et la sortie revient bien pendant qu'un autre fd tient le verrou (non bloquant prouvé) ; session due
  ⇒ relâchée et effacée, une ligne d'audit ; session en cours ⇒ minute muette sans ligne ; record d'un autre boot +
  session concordante ⇒ `sessionRecovery` ; record étranger sans session concordante ⇒ refusé, flag laissé ON ; échec
  d'écriture ⇒ record gardé et sortie 5 ; orphelin ⇒ réconcilié sans écriture ; batterie critique avec session
  indéfinie ⇒ relâchement + veille + session en pause + dette de réarmement ; sans session (interrupteur simple)
  ⇒ relâchement + veille ; flag étranger ⇒ jamais relâché ; record périmé ⇒ `lowBatteryEmergency` ; bonne batterie
  ⇒ rien ; dette de réarmement ⇒ `rearmWithheld`, flag resté OFF, dette conservée ; grille complète sans aucun
  `enable` émis ; **régression : le backstop n'emboîte jamais `LidWriteLock`** (échec nommé après 10 s au lieu d'un
  blocage) ; la section est exclusive de bout en bout, prouvée par une sonde dans le relevé batterie.
- **Registrar** : chaque statut `SMAppService` mappé ; `unknown` n'est jamais traité comme `enabled` ; seul `enabled`
  vaut `isProtecting` ; enregistrement tenté depuis `notFound` (réalité macOS 26) ; idempotence (jamais de
  re-registration d'une approbation en attente) ; un `register()` qui lève est surfacé en `false`, sans état inventé ;
  désenregistrement sans effet quand rien n'est enregistré ; cycle complet ; deep link sans travail privilégié ;
  **le plist livré est conforme au descripteur** (Label, `BundleProgram`, argv, `StartInterval`, `RunAtLoad`, absence
  de `KeepAlive` / `Program` / `MachServices`).
- **CLI** : `recover` sans `--backstop`, `recover --bogus`, `recover --backstop --force`, `recover --backstop extra`,
  `backstop` seul, `backstop <inconnu>`, `backstop status --bogus`, `backstop register extra` ⇒ tous 64 ;
  `backstop status --json` est une lecture (statut et `protecting` cohérents, argv et intervalle présents) ;
  `doctor` et `status` portent le bloc `backstop` ; le chemin rapide sort en 0 sans appel système ; le verrou tenu
  sort en 75.
- **Premier tick au lancement** : une session devenue due pendant que l'app était fermée est terminée par ce premier
  tick, garde batterie active ou coupée.
- **`rowLabel`** : le jour est affiché quand l'échéance n'est pas aujourd'hui, pas quand elle l'est.

NOT_TESTED (matériel) : enregistrement réel de l'agent (`backstop register`), geste d'approbation dans Réglages
Système → Items d'ouverture, cadence réelle de 60 s, résolution de `SMAppService.agent(plistName:)` depuis
`runclosed-cli` dans `Contents/MacOS`, relâchement réel et `pmset sleepnow` du backstop, rendu de la ligne de popup
et du bouton « Ouvrir les items d'ouverture… » sur la build installée. Rien de tout cela n'a été mesuré ; rien n'est
supposé.

### Relecture tour 2 (`ai-review-gate` 0 CRITICAL / 2 WARN + 2 constats du Lord) — 2026-11-07

```
$ arch -arm64 swift build --build-tests     → 0 error, 0 warning
$ arch -arm64 swift test
  RunClosedCoreTests           132 tests, 0 failures   (124 → 132)
  RunClosedMacSystemTests      199 tests, 0 failures   (183 → 199)
  RunClosedPersistenceTests     53 tests, 0 failures   (46 → 53)
  RunClosedHelperSupportTests   27 tests, 0 failures   (inchangé)
  RunClosedAppTests             11 tests, 0 failures   (inchangé)
  → 438 tests, 0 failures (391 avant ce tour : +30)
```

Corrections et contrats ajoutés :

- **WARN `RecoveryBackstopService.Report.exitCode`** — un relâchement critique ÉCHOUÉ sortait 0.
  Désormais `releaseFailed` ⇒ 5, `releaseRefused` ⇒ 3, `released` / `rearmWithheld` / étape absente
  inchangés, et l'échec de session reste prioritaire. Le rendu JSON et le code de sortie ont été
  déplacés dans `RecoveryBackstopService.describe`, donc les 4 tests du map assertent le corps ET le
  code que launchd reçoit réellement (0 relâchement vérifié, 5 échec avec `batteryMutation:
  releaseFailed`, 0 chemin rapide, 75 verrou tenu) — pas seulement l'accesseur du service.
- **WARN `backstopIsProtecting()`** — `SMAppService` `enabled` ne prouve pas que l'agent tourne.
  `backstop_heartbeat.json` est écrit à la fin de CHAQUE run (chemin rapide, app vivante et minute
  occupée compris : 3 tests), hors verrou et sans `pmset`. `RecoveryPolicy.runFreshness` exige le même
  boot, un âge ≤ 180 s et un dernier code ≠ 5 : 7 tests (frais, absent, autre boot, borne inclusive,
  périmé après réveil, dernier run en échec, horodatage futur). Un test relie l'écrivain et le lecteur :
  un run réel du service produit un heartbeat que la règle accepte, et qu'un autre boot refuse.
  `backstop status --json`, `status` et `doctor` gagnent `lastRunAt`, `lastExitCode`, `recentRun`,
  `enforcing` ; le test CLI vérifie sur la machine réelle que `recentRun` est `false` (rien n'a jamais
  tourné ici) et que `enforcing == protecting && recentRun`. Persistance : 7 tests.
- **Lord, inondation du journal** — `rearmWithheld` est audité une fois par épisode (l'état vit dans
  le heartbeat, donc il survit à un redémarrage du processus), et de nouveau après être sorti de
  l'épisode : 3 tests (trois minutes consécutives ⇒ 1 ligne ; sortie puis retour ⇒ 2 ; une minute
  occupée au milieu ne rouvre pas l'épisode).
- **Lord, API morte** — `LowBatteryGuardService.tryTick()` supprimé : aucun appelant, aucun test, et sa
  documentation laissait croire que le backstop l'utilise alors que `tick()` réarme, ce que le backstop
  ne doit jamais faire.

NOT_TESTED (matériel), inchangé par ce tour : l'écriture réelle du heartbeat par launchd dépend de la
résolution de l'agent dans le bundle, qui n'a pas été mesurée. Les chemins de mutation et la règle de
fraîcheur sont couverts par fakes et par un store temporaire ; `recover --backstop`, `backstop
register`, `session start` et `lid-stay-awake on|off` n'ont toujours pas été lancés sur la machine
réelle.

### Relecture tour 3 (`ai-review-gate` WARN advisory, 0 CRITICAL, 7 constats) — 2026-11-07

```
$ arch -arm64 swift build --build-tests     → 0 error, 0 warning
$ arch -arm64 swift test
  RunClosedCoreTests           135 tests, 0 failures   (132 → 135)
  RunClosedMacSystemTests      199 tests, 0 failures   (199, réécriture à contrat égal)
  RunClosedPersistenceTests     53 tests, 0 failures
  RunClosedHelperSupportTests   31 tests, 0 failures   (27 → 31)
  RunClosedAppTests             11 tests, 0 failures
  → 438 tests, 0 failures (422 avant ce tour : +7)
```

Le verdict est `WARN (advisory)`, 0 CRITICAL — la porte passe — mais 7 constats portaient sur du code
écrit dans ce lot. Tous traités :

- **Popup (WARN)** — `backstopRow()` ne regardait que `status.isProtecting`, donc un agent approuvé
  dont le `BundleProgram` ne se résout pas affichait *rien* dans le popup alors que le CLI du même diff
  rapportait `enforcing: false`. Exactement la panne silencieuse que le heartbeat existe pour
  attraper. Le popup applique désormais la même règle (`isProtecting && runFreshness(...).isEnforcing`)
  et affiche « Recovery backstop enabled but not running (see log) ».
- **Enregistrement au lancement (WARN)** — `registerIfNeeded()` enregistrait depuis `notRegistered`,
  or c'est l'état que laisse un `backstop unregister` : lancer l'app annulait donc en silence une
  décision explicite de l'opérateur. L'opt-out est maintenant persisté (`UserDefaults`, clé
  `backstopOperatorOptedOut`), honoré par l'enregistrement automatique (`automatic: true`, le seul
  appel fait au lancement), et effacé par un `backstop register` explicite.
- **Test dépendant de la machine (WARN)** — l'assertion `recentRun == false` contre le binaire réel
  passait sur une machine où l'agent n'a jamais été installé et **échouait sur le Mac déployé** que ce
  lot cible. Remplacée par des invariants : `enforcing == protecting && recentRun`, cohérence
  `lastRunAt`/`lastExitCode`, et « non enregistré ⇒ jamais enforcing ».
- **Test qui ne pouvait pas échouer (WARN)** — `testRefusedBatteryReleaseExits3` n'assertait que dans
  un `if` jamais pris. Le refus est une course réelle non stagingeable par la surface publique (retirer
  le record dans le readback batterie fait passer `evaluate()` en `notOwned` et dégrade en alerte, donc
  aucun relâchement n'est tenté) : le map est désormais asserté sur un `Report` construit, avec
  `released` et `rearmWithheld` côte à côte.
- **Minute occupée (suggestion, retenue)** — `runFreshness` ne rejetait que le code 5, donc un run à 75
  (verrou tenu) comptait comme preuve. Un nouveau cas `lastRunBusy` refuse : une minute qui n'a pas pu
  agir ne prouve pas que l'agent peut agir. Un refus (3) reste frais — c'est le backstop qui marche.
- **Échéance à 7 jours (suggestion)** — `rowLabel` affichait le jour de la semaine, or une échéance à
  exactement une semaine tombe le MÊME jour : « Until Tue 14:30 » un mardi se lit comme aujourd'hui.
  Au-delà de 7 jours la date est ajoutée ; en deçà d'un jour, heure seule.
- **Ordre de l'audit (suggestion)** — `performRelease` lisait `recordBootIDBefore` après l'étape
  session, qui peut effacer `owned_lid.json` sur le même tick. La valeur est maintenant capturée avant.

NOT_TESTED, inchangé : rien de tout cela n'a été mesuré sur matériel. Le popup et la persistance de
l'opt-out sont du code AppKit/`UserDefaults` couverts par lecture et par tests de la couche service ;
`recover --backstop`, `backstop register`, `session start` et `lid-stay-awake on|off` n'ont toujours
pas été lancés sur la machine réelle.

### Relecture tour 4 (`ai-review-gate` WARN advisory, 0 CRITICAL, 6 constats) — 2026-11-07

```
$ arch -arm64 swift build --build-tests     → 0 error, 0 warning
$ arch -arm64 swift test
  RunClosedCoreTests           135 tests, 0 failures
  RunClosedMacSystemTests      201 tests, 0 failures   (199 → 201)
  RunClosedPersistenceTests     53 tests, 0 failures
  RunClosedHelperSupportTests   31 tests, 0 failures
  RunClosedAppTests             11 tests, 0 failures
  → 438 tests, 0 failures (429 avant ce tour : +2)
```

- **Couverture CI des tests CLI (WARN, le seul vrai défaut)** — `cliURL()` ne cherchait que
  `.build/out/Products/Debug/runclosed` (layout Xcode) et le bundle, alors que la CI fait
  `swift build --build-tests && swift test`, donc le binaire est dans `.build/debug/` : en CI tous
  les tests de sous-processus étaient **silencieusement skippés** et la CI restait verte sans jamais
  vérifier le contrat exit-64, `backstop status --json` ni les blocs `doctor`/`status`. Pire en local :
  un bundle périmé était testé à la place du code. Les trois chemins sont maintenant essayés du plus
  frais au plus ancien, et l'absence de binaire en CI **échoue** au lieu de skipper.
- **`noLockedRunYet` (suggestion, retenue)** — une minute `nothingToDo`/`appAlive` sort avant le verrou
  et avant `pmset` : elle prouve que l'agent démarre, pas qu'il peut agir. `completedLockedRun` est
  enregistré dans le heartbeat (collant sur le même boot seulement) et `runFreshnessFull` refuse tant
  qu'aucune section verrouillée n'a abouti sur ce boot. 3 tests.
- **`unregister` sur `notFound`** — macOS 26 rapporte l'état jamais-enregistré comme `notFound`, donc
  `unregister()` y échouait et la CLI annonçait un faux échec pour un démontage sans effet. Traité
  comme `notRegistered`.
- **Test « unknown status »** — il ré-affirmait `.notRegistered`, déjà couvert. Il passe maintenant un
  vrai statut non reconnu (`SMAppService.Status(rawValue: 99)`) et vérifie qu'il donne `.unknown`, pas
  `.enabled`.
- **Test d'isolation du heartbeat** — il ne comparait que les URL ; il capture désormais l'existence et
  le mtime du fichier réel avant/après le run, donc un service qui écrirait aux DEUX chemins échoue.
- **Répertoires temporaires** — `addTeardownBlock` supprime chaque arbre créé (le test de grille à lui
  seul en construisait 32 par exécution).

NOT_TESTED : inchangé. Rien de tout cela n'a été mesuré sur matériel ; les tests CLI tournent
désormais réellement en CI, ce qui est vérifiable ici au prochain passage.

### Relecture tour 5 (`ai-review-gate` WARN advisory, 0 CRITICAL, 7 constats) — 2026-11-07

```
$ arch -arm64 swift build --build-tests     → 0 error, 0 warning
$ arch -arm64 swift test
  RunClosedCoreTests           136 tests, 0 failures
  RunClosedMacSystemTests      203 tests, 0 failures   (201 → 203)
  RunClosedPersistenceTests     53 tests, 0 failures
  RunClosedHelperSupportTests   31 tests, 0 failures
  RunClosedAppTests             11 tests, 0 failures
  → 438 tests, 0 failures (431 avant ce tour : +3)
$ CI=true swift test --filter RunClosedMacSystemTests.RecoverCommandTests → 13 tests, 0 échec, 0 skip
```

- **La garde CI faisait l'inverse de sa doc (WARN, régression du tour 4)** — mon
  `if CI { throw XCTSkip }` skippait en CI et échouait en local, exactement le contraire de ce que le
  commentaire annonçait, annulant le commit `9bee394`. Corrigé : en CI un binaire manquant
  **`XCTFail`**, en local c'est un skip. Vérifié avec `CI=true` : les 13 tests CLI s'exécutent
  réellement, aucun skip.
- **Le backstop consommait les alertes de l'app (WARN)** — `protectiveStep` persistait le latch issu de
  la politique, donc `warnedLow` / `warnedCritical` / `failedReleaseSleepTried` étaient marqués alors
  que le backstop n'affiche AUCUNE notification. L'opérateur rouvrait l'app dans le même épisode de
  décharge et recevait `.alreadyWarned` : l'alerte batterie faible n'était jamais montrée. Seule la
  dette de réarmement (`releasedByGuard`) est désormais écrite par ce chemin — c'est le signal de
  réactivation pour l'app, pas une affirmation que quelqu'un a été prévenu. 2 tests.
- **Test contre la mauvaise règle (WARN)** — `testARealRunProducesAHeartbeatTheCLIAcceptsAsEnforcing`
  notait un run de chemin rapide avec `runFreshness`, le wrapper qui forçait la preuve de section
  verrouillée ; la production utilise `runFreshnessFull`. Le test passait donc sur une règle que
  personne n'applique. Il utilise maintenant `runFreshnessFull` + `freshnessInput()` sur un run qui a
  réellement pris le verrou.
- **Wrapper dangereux** — `runFreshness(heartbeat:…)` codait `completedLockedRun: true` en dur ; un
  futur appelant aurait pu lever le refus ADR 023 pour un agent dont le chemin verrouillé n'a jamais
  tourné. Le paramètre est maintenant requis.
- **Échec d'écriture du heartbeat silencieux** — `save` était ignoré ; en cas d'échec,
  `rearmWithheldReported` ne persistait pas (retour du flood) et le CLI refusait sans explication. Une
  ligne stderr rend la panne diagnosticable (l'action protectrice, elle, a déjà eu lieu).
- **Détail, non retenu** — l'assertion `rowLabel` dépend de l'époque fixe ; et un `lid -> on` non
  vérifié laisse un ancien record de session en place. Les deux sont sans effet observable (les étapes
  sont idempotentes et confirmées par readback) ; non modifiés, pour ne pas élargir le diff sans
  défaut.

NOT_TESTED : inchangé. Rien de tout cela n'a été mesuré sur matériel.

### Addendum round 2 — le backstop respecte le coupe-circuit batterie (2026-11-07)

```
$ arch -arm64 swift build --build-tests     → 0 error, 0 warning
$ arch -arm64 swift test
  RunClosedCoreTests           136 tests, 0 failures
  RunClosedMacSystemTests      207 tests, 0 failures   (203 → 207)
  RunClosedPersistenceTests     53 tests, 0 failures
  RunClosedHelperSupportTests   31 tests, 0 failures
  RunClosedAppTests             11 tests, 0 failures
  → 438 tests, 0 failures (434 avant : +4)
```

Constat du Lord : l'app saute l'étape batterie quand `LowBatteryGuardSettings.isEnabled()` est faux et garde
l'étape session (`AppMain.runLowBatteryTick`) ; le backstop tournait `protectiveStep()` quand même, donc un
opérateur ayant coupé la garde recevait `disablesleep 0` + `pmset sleepnow` de launchd une minute plus tard.

`batteryGuardEnabled` est injecté (live = `LowBatteryGuardSettings.isEnabled()`) et porté par
`RecoveryPolicy.Facts`. 4 tests :

- garde coupée + batterie critique + flag nôtre ⇒ flag ON inchangé, aucun relâchement, aucun `sleepnow`,
  aucune ligne d'audit `batteryRelease` ;
- garde coupée + session échue ⇒ la session se termine (relâchement vérifié) et la veille n'est JAMAIS
  appelée par l'étape session ;
- garde coupée + rien d'autre ⇒ la minute reste gratuite (`nothingToDo`) ;
- garde par défaut ⇒ le relâchement critique a toujours lieu.

**Contre-épreuve** : en retirant `&& facts.batteryGuardEnabled` de `plan()`, le premier test échoue sur le
flag, le relâchement, la veille et l'audit — la correction est porteuse, pas décorative.
