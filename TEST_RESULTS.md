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

## G1 / G2
NOT_TESTED — à venir (voir PROGRESS.md).
