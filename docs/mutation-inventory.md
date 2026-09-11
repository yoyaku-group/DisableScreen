# Inventaire des points de mutation — archive `a7665b5`

Chaque ligne où `main.py` / `launcher.m` change un état hors du process. Base des invariants RunClosed (§ADR 002/006). Effet **global** = visible par les autres apps / persistant ; **local** = confiné au process.

| # | Fichier:fonction | Cible | Permission | Effet | Code retour vérifié ? | Readback ? | Persistance | Récupération actuelle |
|---|---|---|---|---|---|---|---|---|
| M1 | `main.py:_sls_set_display_enabled` | 1 écran (`display_id`) | user | **global** (topologie) | oui (begin/complete) | non | jusqu'au réactivation / reboot | `applicationWillTerminate_` réactive les `disabled_displays` connus (mémoire seule) |
| M2 | `main.py:set_display_resolution` → `CGDisplaySetDisplayMode` | 1 écran | user | **global** (mode) | **NON (A05)** | non | jusqu'au changement suivant | aucune (pas de retour auto si mode inutilisable) |
| M3 | `main.py:set_display_brightness` (builtin) → DisplayServices/CoreDisplay | écran intégré | user | global (luminosité matérielle) | partiel | non | matériel | aucune (pas de restauration à la sortie) |
| M4 | `main.py:_iokit_brightness(value)` | **TOUS** les `IODisplayConnect` (A02) | user | global (DDC broadcast) | par service | non | matériel | aucune |
| M5 | `main.py:_apply_dim` overlay `NSWindow` | 1 écran | user | local (fenêtre) | n/a | n/a | tant que l'app vit | fermeture de fenêtre à la sortie du process |
| M6 | `main.py:_set_lid_stay_awake` → `sudo pmset -a disablesleep 0\|1` | **système** | **root** (NOPASSWD) | **global + persistant** (A03) | rc seulement | non | **survit au quit ET au reboot** | **AUCUNE** (jamais restauré à la sortie) |
| M7 | `launcher.m:handleSM` → `SMAppService register/unregister` | login item de l'utilisateur | user | global (LaunchServices) | oui (`ok`, status) | oui (`--status`) | persistant | self-heal au lancement (A17 : trop large) |
| M8 | `main.py:_write_wants_login_item` → `settings.json` | `~/DisableScreen/settings.json` | user | local (fichier) | non | relecture | persistant | écrasement idempotent |

## Conclusions pour la conception

- **M6 est le seul effet root, global ET persistant sans propriété ni récupération** → cœur du modèle de lease/propriété (ADR 004, invariants 6/8/9). Fix A03 = enregistrer `{prev, boot_uuid, set_at}` et ne restaurer que ce qu'on possède.
- **M4 (broadcast) viole l'invariant 1** (« une commande pour A ne touche pas B ») → supprimé (A02).
- **M2 viole l'invariant 3** (« une erreur ne devient jamais un succès ») → résultat typé + readback (A05).
- **M1** doit revalider la topologie au moment de l'effet (invariant 4, A04).
- M3/M4/M5 : `brightness` doit choisir **un** backend explicite par cible (ADR : `softwareDim` pour externe, `native` pour intégré), jamais cumuler overlay + write matériel.
