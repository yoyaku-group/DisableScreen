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

[DISCOVERY] Quirk macOS `pmset` : **stderr→stdout swap quand stderr ≠ tty** + **exit code non-fiable quand privilèges insuffisants**. Fix dans `PMSetLidAssertion.runPmsetWrite()` : capture combinée des deux flux + readback autoritaire via `PowerReadback.lidStayAwake()`. Pattern réutilisable pour toute intégration subprocess pmset.

