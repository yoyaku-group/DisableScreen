import Foundation

// runclosed-privileged-helper — A14 root LaunchDaemon (ADR 016).
//
// THIS TRANCHE: registration/status skeleton only. No XPC listener yet
// (deliberate sequencing: registration first, XPC once that is proven on
// real hardware — never debug both at once). The daemon starts, logs, and
// waits for SIGTERM. It performs NOTHING privileged in this tranche.
//
// When XPC lands, the exposed API is frozen by ADR 016 to:
//   - setDisableSleep(Bool)  → /usr/bin/pmset -a disablesleep 0|1
//   - health/version
// and NOTHING else: no generic exec, no shell, no command strings, no
// arbitrary paths or arguments, no sudo, no other pmset settings.
// Callers will be authenticated by code-signing requirement (the app's
// Apple identity) — ad-hoc signing is NOT a valid A14 configuration.

setvbuf(stdout, nil, _IOLBF, 0)
FileHandle.standardError.write(Data("[runclosed-helper] started (registration skeleton, no XPC yet — ADR 016)\n".utf8))

let sigsrc = DispatchSource.makeSignalSource(signal: SIGTERM)
sigsrc.setEventHandler {
    FileHandle.standardError.write(Data("[runclosed-helper] SIGTERM — exiting cleanly\n".utf8))
    exit(0)
}
signal(SIGTERM, SIG_IGN)
sigsrc.resume()

dispatchMain()
