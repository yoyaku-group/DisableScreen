# Roadmap

## App Store readiness

Current state: the app runs, auto-launches, is localized (en/fr), and is
ad-hoc signed. Good enough for personal use on this Mac. Not yet App
Store-submittable.

To ship on the Mac App Store, the following is still required:

- [ ] **Developer ID signing** — replace `codesign --sign -` (ad-hoc) with
      a real Apple Developer ID certificate. Requires an Apple Developer
      Program membership.
- [ ] **Notarization** — submit the signed `.app` to Apple's notary
      service (`xcrun notarytool submit ... --wait`) and staple the ticket
      (`xcrun stapler staple`). Required for distribution outside the App
      Store; good hygiene either way.
- [ ] **Privacy manifest** — add `Contents/Resources/PrivacyInfo.xcprivacy`
      declaring required-reason API use (for us: `CGDisplay*` /
      `IOKit` / `pmset` via sudo). Mandatory for App Store submissions
      since 2024.
- [ ] **App Sandbox entitlements** — add `Contents/entitlements.plist`
      with `com.apple.security.app-sandbox = true` and the minimum
      capabilities we actually need. The current `pmset disablesleep` via
      sudoers will NOT survive sandboxing — we would need to either drop
      that feature for the App Store build, or move it behind a helper
      tool with `SMJobBless`. Decision to make.
- [ ] **Update `build.sh`** to accept a `SIGN_IDENTITY` env var and
      switch between ad-hoc (dev) and Developer ID (release) builds.
