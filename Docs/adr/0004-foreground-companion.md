# ADR 0004 — Foreground companion session model

## Status

Accepted

## Context

Users want phone-in-pocket hands-free use. iOS aggressively limits background microphone, Bluetooth HFP continuity, and networking for third-party apps. Meta DAT sessions are tied to an active mobile app integration. Promising ChatGPT-style always-listening wake word in Phase 1 would be dishonest.

## Decision

Phase 1–2 product model:

- Nova is a **foreground companion**: user starts a session from the app (or a supported Meta entry point), then may pocket the phone **while the app remains active** as allowed by iOS.
- Document that locking the phone / suspending the app may pause or end the session.
- No always-on wake word commitment until measured against current iOS background audio + DAT capabilities.
- Handle DAT pause/resume (hinge close, glasses off, tap) as first-class session states in UI and orchestrator.

Session state machine (domain):

```text
idle → registering → ready → active ⇄ paused → ending → idle
                         ↘ failed
```

## Consequences

**Positive:** honest UX; simpler audio lifecycle; fewer App Store policy surprises.

**Negative:** not fully hands-free from cold start; Phase 3 wake word remains research.

## Alternatives considered

- Background audio entitlement as primary UX — deferred; investigate post-MVP with legal/policy review.
- Rely solely on Meta AI as host — rejected for Nova’s custom Realtime pipeline ownership.
