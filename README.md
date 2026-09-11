# DisableScreen

A macOS menu-bar app to manage external displays. Built for people who dock a
laptop to a USB-C portable monitor and want **real brightness control** — not
just a slider that the OS silently ignores.

## What it does

- **Toggle external displays** on/off from the menu bar (SkyLight under the hood)
- **Brightness slider** for each external display, with three strategies tried in
  order: DDC via IOKit → CoreDisplay → DisplayServices. As a last resort, falls
  back to a **translucent black overlay window** layered above the screen at
  `NSScreenSaverWindowLevel` — the only reliable path on Apple Silicon when
  driving USB-C portable monitors (e.g. ASUS MB16AH) that ignore both DDC writes
  and `CGSetDisplayTransferByFormula`.
- **Resolution picker** (`NSPopUpButton`) listing the modes reported by
  `CGDisplayCopyAllDisplayModes`
- **DDC button** → opens `x-apple.systempreferences:com.apple.preference.displays`
- **Auto-launch at login** via `SMAppService.mainAppService` (signed binary required,
  hence the Obj-C launcher wrapper)
- **"Keep awake with lid closed"** toggle, implemented via `pmset disablesleep`
  through a NOPASSWD sudoers whitelist
- Localized in English and French

## Why a Python + Objective-C hybrid?

macOS launches login items with a sanitized PATH
(`/usr/bin:/bin:/usr/sbin:/sbin`), and `/usr/bin/python3` is the Apple stub
**without PyObjC**. So the app bundle ships:

- `Contents/MacOS/DisableScreen` — a small Obj-C launcher (`launcher.m`) that
  resolves a real Python framework path (`/Library/Frameworks/Python.framework/...`
  or Homebrew) and `execv`s it.
- `Contents/Resources/main.py` — the entire UI/business logic in Python with
  PyObjC. Easy to iterate, no Xcode project.

## Requirements

- macOS 12 (Monterey) or later
- Python 3.12 with PyObjC (`python3 -c "import AppKit"` must succeed)
- For the lid-stay-awake feature: a `pmset` NOPASSWD sudoers entry (see below)
- For auto-launch: `codesign` (the build script does an ad-hoc signature,
  which is enough for `SMAppService`)

## Build

```bash
./build.sh
# → ./DisableScreen.app
```

The build script:

1. Compiles `launcher.m` with `clang -fobjc-arc`
2. Copies `main.py`, `Info.plist`, `AppIcon.icns`, and the `.lproj/` bundles
3. Ad-hoc signs the bundle with `codesign --force --sign -`

For wider distribution, swap ad-hoc for a Developer ID identity and notarize
the bundle (see `ROADMAP.md` for the full App Store readiness checklist).

## Install

```bash
# 1. Copy the bundle
cp -R DisableScreen.app /Applications/

# 2. (Optional) Whitelist pmset for passwordless lid-stay-awake control
sudo tee /etc/sudoers.d/disablescreen-pmset >/dev/null <<'EOF'
%admin ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep *
EOF
sudo chmod 0440 /etc/sudoers.d/disablescreen-pmset
```

The app stores its log and user settings under `~/DisableScreen/`:

```
~/DisableScreen/
├── disablescreen.log
├── launcher.log
└── settings.json
```

## Tests

```bash
python3 test_e2e.py
```

Checks the app bundle, the running process, the log file, and live display
detection via CoreGraphics.

## License

MIT — see [LICENSE](LICENSE).

Copyright (c) 2026 Benjamin Belaga.