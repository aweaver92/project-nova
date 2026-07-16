# ADR 0003 — Ephemeral Realtime credentials

## Status

Accepted

## Context

OpenAI API keys must never ship in the IPA or land in git. Realtime sessions need short-lived client secrets. Production requires revocation, metering, and abuse controls.

## Decision

1. Long-lived OpenAI key lives only on a backend token service (or local stub for Phase 0).
2. App authenticates to the backend, receives an ephemeral Realtime client secret + expiry.
3. App stores the token in Keychain via `SecureTokenStore`.
4. `OpenAIRealtimeProvider` refreshes before expiry; on 401, force re-fetch.
5. Session TTL and idle timeout enforced client-side; backend may also kill sessions.

Phase 0 ships `TokenService` protocol + `StubTokenService` (reads from environment / xcconfig for local dev only) + `KeychainTokenStore`.

```swift
protocol TokenService: Sendable {
    func fetchRealtimeClientSecret() async throws -> EphemeralCredential
}

protocol SecureTokenStore: Sendable {
    func save(_ credential: EphemeralCredential) throws
    func load() throws -> EphemeralCredential?
    func clear() throws
}
```

## Consequences

**Positive:** no plaintext keys in app binary for production path; rotation and metering possible.

**Negative:** requires a backend before public TestFlight; stub path must be gated behind `#if DEBUG` / build config.

## Alternatives considered

- Embed API key in Info.plist — rejected (extractable, unrevocable).
- User-pasted API key only — acceptable for personal debug builds, not default production architecture.
