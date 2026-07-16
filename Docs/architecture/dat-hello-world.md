# DAT integration notes (hello-world)

## Current state

`MetaDATWearableSession` and `MetaDATFrameCapture` implement Nova domain ports with a **mock registration/session path** so the app boots without the closed Meta SDK on every machine.

## Wire official SDK (on Mac + developer access)

1. Add Meta Wearables DAT Android/iOS packages per [integration guide](https://wearables.developer.meta.com/docs/build-integration-ios).
2. Register `APPLICATION_ID` / client token in Info.plist (`DAMEnabled` defaults true).
3. Replace mock bodies in `Sources/NovaData/MetaDAT/MetaDATAdapters.swift`:
   - `register()` → DAT registration deeplink into Meta AI
   - `start()` → `DeviceSession`
   - `captureStill()` / live look → `MWDATCamera` stream + photo APIs
4. Keep HFP setup in `AudioSessionCoordinator` **before** starting camera stream (Meta ordering constraint).

## Hello-world checklist

- [ ] Meta developer org + release channel
- [ ] Sample DAT app builds against your glasses firmware
- [ ] Nova mock session UI: Register → Start → Active
- [ ] Swap mock → real DAT
- [ ] Confirm `.bluetoothHFP` preferred input
- [ ] Confirm pause on hinge close / glasses off
