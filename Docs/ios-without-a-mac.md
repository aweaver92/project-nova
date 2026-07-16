# Shipping Nova to an iPhone without owning a Mac

Target device: **iPhone 11** (iOS 15.2+, meets Meta AI app / DAT requirements).
Dev machine: **Windows**. No Mac owned.

## The one hard rule

iOS apps can only be compiled and code-signed with Xcode, which runs only on
macOS. No cross-platform framework removes this — they all still need a Mac for
the final build. Since the Meta Wearables Device Access Toolkit is a native
Swift SDK embedded in the phone app, Nova must be a native iOS app.

Conclusion: we never need to *own* a Mac, but we must *rent* macOS for the
build/sign step. We do that in the cloud.

## Two-stage pipeline

### Stage 1 — Free cloud compile + test (no Apple account)

[`.github/workflows/ios-build.yml`](../.github/workflows/ios-build.yml) builds the
[`Nova/`](../Nova) Swift package for the iOS Simulator on a GitHub Actions macOS
runner and runs the unit tests. This requires no Apple Developer account and no
signing secrets, because simulator builds are unsigned. It is our verification
gap closer: push to GitHub and the runner confirms the Swift compiles for iOS.

Alternatives to GitHub Actions: **Codemagic** or **Bitrise** (GUI-driven, built
for "no Mac" mobile teams, generous free tiers).

### Stage 2 — On-device via TestFlight (requires Apple Developer, $99/yr)

To run on the physical iPhone 11 with no Mac:

1. Enroll in the Apple Developer Program ($99/yr).
2. Extend the CI to *archive* and *sign* the app, then upload to App Store
   Connect (via `xcodebuild -exportArchive` + `altool`/`fastlane pilot`, or
   Codemagic's built-in publishing). Signing certificates/profiles are stored as
   CI secrets — Apple lets CI manage signing without a local Mac.
3. Install **TestFlight** from the App Store on the iPhone 11 and download the
   build over the air. No cable, no Mac.

## Getting the repo to GitHub (first time)

Git is not yet installed on this machine. Once installed:

```powershell
winget install Git.Git
# reopen the terminal, then from the project root:
git init
git add .
git commit -m "Nova: sim + iOS package + CI"
# create an empty repo on github.com, then:
git remote add origin https://github.com/<you>/<repo>.git
git push -u origin main
```

The `iOS Build` workflow runs automatically on push and reports whether the
Swift package builds for iOS.

## Notes / gotchas

- The unit-test step uses the `Nova-Package` scheme (SwiftPM's auto-generated
  aggregate). If the first CI run reports an unknown scheme, check the
  "List package schemes" step output and adjust the scheme name.
- `nova-sim/` stays the fast Windows-side test harness for conversation logic;
  the iOS CI validates the Swift adapters that can't run on Windows.
