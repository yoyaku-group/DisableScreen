# DECISIONS — DisableScreen → RunClosed

Décisions d'architecture. Un ADR = une décision. Nom RunClosed **provisoire** (package Swift + binaire CLI `runclosed` uniquement ; repo/bundle id inchangés jusqu'à G5).

| ADR | Décision | Raison / compromis |
|---|---|---|
| 001 | Swift pour le produit distribué ; Python conservé comme app quotidienne + snapshot d'audit. | Supprimer la dépendance Python externe et le pont de bundle. Migration incrémentale, pas big bang. |
| 002 | Noyau Swift (`RunClosedCore`) indépendant d'AppKit et des API macOS via protocoles injectables. | Tests déterministes (horloge, backends fakes) sans matériel. |
| 003 | Cible macOS 14+, Apple Silicon primaire ; Intel = compilé, non testé. Zéro dépendance externe (parsing CLI maison). | Limite la matrice ; pas de badge « supporté » sans essai. Le shell tourne sous Rosetta → tout build force `arch -arm64`. |
| 004 | Un seul propriétaire logique des demandes de maintien éveillé (lease). | UI et CLI ne doivent pas détenir d'états power contradictoires. |
| 005 | Modèle de propriété pour `pmset disablesleep` : on ne restaure que ce qu'on a posé, prouvé par `{prev, boot_uuid, set_at}` + readback. Sinon `conflict` → ne pas toucher. Jamais de `disablesleep 0` inconditionnel. | M6 est le seul effet root/global/persistant sans récupération (voir mutation-inventory). |
| 006 | Broadcast DDC/IOKit supprimé ; `brightness.external = softwareDim` (honnête), pas de faux DDC. | Aucun transport par-écran prouvé (A02, invariant 1). |
| 007 | `run --lid` refuse tant que le backend capot n'est pas qualifié (Phase 3, opt-in matériel). `run --idle-only` = premier wrapper réel sur API publique `IOPMAssertionCreateWithName`. | Une assertion idle publique ne couvre pas la fermeture du capot (S01). Pas de promesse non tenue. |
| 008 | Distribution directe signée/notarisée avant toute variante App Store. | Le Store exige des API publiques ; la notarisation ne transforme pas une API privée en publique. |
| 009 | **Un effet global/root n'est jamais muté sans baseline observable, et un état de récupération n'est jamais supprimé avant qu'un readback ne confirme le retour à l'état visé.** UNKNOWN ≠ OFF ; succès d'API ≠ succès observable. (Généralise ADR 005 aux 3 chemins : flag capot, écrans possédés, leases.) | Audit pré-merge PR #1 (2026-09-12) : 3 défauts recovery où un pré-état inconnu était traité comme OFF, où l'ownership était lâché avant readback, et où un écran non ré-activé perdait son id. La correction fait de l'observation (pas du rc d'API seul) la condition de tout write/delete d'état de récupération. |
| 010 | **Logique de présentation = cible pure sans AppKit**, testable sur Linux CI ; `AppDelegate` reste fin (fil de la vue, pas de la vérité). Le ViewModel + renderer vivent dans `RunClosedApp`, consommés par les UI natives futures (AppKit menu-bar en G2a, autres surfaces plus tard). | G2a (2026-09-14) : le `SnapshotBuilder.make()` doit rendre le tri-état `unknown` distinct de `off`, sinon la couche UI re-ment. La détection d'ambiguïté vit aussi dans le builder (défense en profondeur) car un futur backend (G2b) peut passer des snapshots pré-construits où le flag `DisplayInventory` n'est pas posé. Le test `testAmbiguousDisplayFlagged` est tombé sur cette vérité pendant l'écriture — c'est exactement la classe de garde-fou que le ViewModel pur permet. |

## Décisions de périmètre (cette tranche G0–G2)

- Même repo, branche de mission `agent/claude/20260911/…` (worktree lié via `yy mission`). Register forcé (`--force-capacity`) : `--headless` n'exécute aucun harness, coût CPU nul ; charge due aux sessions voisines.
- Tests matériels (capot, écran externe MB16AH) derrière `RUNCLOSED_HW_OPTIN=1`, exécution seulement avec Ben présent. Un seul écran (XDR intégré) branché → externe = `BLOCKED_HARDWARE`.
- Aucun backend capot privé (`coke`) exploré ici (décision post-qualification).
