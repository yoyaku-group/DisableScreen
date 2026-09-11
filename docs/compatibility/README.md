# Matrice de compatibilité

Honnête par construction : une ligne n'apparaît que si elle a été **testée** sur
la machine nommée. La compilation seule ne donne aucun badge « supporté ».

| Machine | macOS | idle assertion | capot (closed-lid) | écran externe |
|---|---|---|---|---|
| Apple M5 Max | 26.6 | PASS (IOPMAssertionCreateWithName, vérifié via `pmset -g assertions`) | NON QUALIFIÉ (`run --lid` refuse ; protocole `scripts/hardware/lid-qualification.sh`, opt-in) | BLOCKED_HARDWARE (un seul écran XDR intégré branché) |

`lid: unqualified` signifie exactement cela : le maintien capot fermé n'a pas été
prouvé sur ce matériel. Une assertion idle publique **ne couvre pas** la fermeture
du capot (Apple, `kIOPMAssertionTypePreventUserIdleSystemSleep`).
