# Nova Feature Rollout Roadmap

Rollout plan for the Nova assistant feature set (Skills, Workspaces, Knowledge,
Suggestions, Memory, and beyond). This complements the architecture-focused
[`roadmap.md`](roadmap.md): that doc tracks the platform (voice pipeline, vision,
DAT), while this one tracks user-facing capabilities.

Status legend: ✅ shipped · 🟡 in progress · ⬜ planned · ⛔ blocked/deferred

---

## Phase 1 — Skills, Workspaces, Knowledge, Suggestions, Memory ✅ (shipped)

Delivered on-device, built on the existing `ToolRouter` tool-calling round-trip
and the `profileProvider` instruction-injection pattern.

| Capability | What shipped |
|-----------|--------------|
| Workspaces | `Workspace` model, `FileWorkspaceStore` (seeded "Default", persisted active selection), context injected into each session, `set_workspace` voice tool, Workspaces tab with active indicator |
| Scoped memory | `FileConversationMemory` tags turns with `workspaceId`; `recent(workspaceId:)` / `summary(workspaceId:)` for per-project continuity |
| Skills / macros | `Skill` + `SkillStep` models, `FileSkillStore`, hybrid `SkillRunner` (deterministic steps local, freeform → model), trigger-phrase matching, `run_skill` tool, catalog injection, Skills tab editor |
| Bookmarks | `FileBookmarkStore`, "bookmark this" detection, `bookmark_conversation` tool |
| Knowledge search | `KnowledgeSearch` (keyword-ranked across notes, bookmarks, facts, conversation), `search_knowledge` tool, Knowledge tab |
| Follow-up suggestions | `FollowUpSuggester` (Responses API) → suggestion chips; `sendUserText` continues the conversation on tap |
| Voice drafting | `draft_message` tool (email/text compose sheets, to-do/doc → reminder/note; auto-send deferred) |

**Deferred out of Phase 1 (tracked below):** cross-device / Claude context
transfer, automated (no-tap) email/text sending, semantic (embedding) search,
spoken follow-ups.

---

## Phase 2 — Proactivity & smarter memory ⬜

Make Nova feel less like a command line and more like an assistant that
remembers and anticipates.

| ID | Item | Scope / approach | Depends on | Acceptance |
|----|------|------------------|-----------|------------|
| P2.1 | Memory compaction / summarization | Periodically summarize old turns into a durable per-workspace "memory digest" so context survives beyond the rolling window without bloating the prompt | Phase 1 scoped memory | "What did we decide last week?" answered from a digest, not raw turns |
| P2.2 | Semantic knowledge search | Add on-device embeddings (Core ML / `NLEmbedding`) as a ranking layer over the current keyword search; keep keyword as fallback | `KnowledgeSearch` | Finds relevant notes even without exact keyword overlap |
| P2.3 | Scheduled & proactive skills | Time/location triggers for skills (e.g. "every weekday 8am run my Commute skill") via local notifications / `UNCalendarNotificationTrigger`; opt-in | Skills core | A skill fires on schedule and speaks a summary when opened |
| P2.4 | Spoken follow-ups (toggle) | Optionally have Nova offer 1 follow-up out loud instead of only chips; default off to avoid chattiness | Follow-up suggester | Setting toggles spoken vs. chip suggestions |
| P2.5 | Skill import/export & sharing | Encode a skill as shareable JSON (share sheet / deep link) so skills can be backed up or shared | Skills store | Export a skill, re-import on a fresh install, it runs |

---

## Phase 3 — Cross-device & multi-model (Claude pipeline) ⛔ (needs backend)

The largest deferred item. Requires infrastructure that does not exist yet.

| ID | Item | Scope / approach | Prerequisite |
|----|------|------------------|--------------|
| P3.1 | Sync backend | A small cloud service (auth + storage) to hold workspaces, memory, skills, bookmarks per user | Hosting + auth decision |
| P3.2 | Context transfer between devices | Push/pull the active workspace + recent memory so a conversation started on glasses continues on phone/desktop | P3.1 |
| P3.3 | Claude pipeline | Route selected turns to Claude (long-form reasoning / large-context tasks) while Realtime stays the voice front-end; a second model runtime behind a new provider | P3.1, provider abstraction |
| P3.4 | Handoff UX | "Continue this on my laptop" / resume banners | P3.2 |

**Why deferred:** needs a cloud backend and a second model runtime; none exists
today. Everything in Phases 1–2 is intentionally on-device.

---

## Phase 4 — Actions & integrations ⬜

Broaden what Nova can *do*, within iOS limits.

| ID | Item | Scope / approach | Notes |
|----|------|------------------|-------|
| P4.1 | Automated send (where allowed) | Investigate Shortcuts automations / `INSendMessageIntent` for permitted auto-send paths; keep compose-sheet fallback | iOS restricts silent send; may stay assistive |
| P4.2 | Home Assistant expansion | Scenes, sensor queries, area/device discovery beyond the current on/off tool | Existing `HomeAssistantTool` |
| P4.3 | Richer drafting | Templates, tone control, and reminder/calendar round-trips from drafts | `draft_message` |
| P4.4 | More first-party skill steps | HTTP webhook step, conditional step, delay step for richer macros | `SkillStep` enum |

---

## Phase 5 — Vision & Meta AI registration ⛔ (currently blocked)

Tracked separately because it depends on Meta's companion-app registration,
which is currently failing ("Internal Error"). Kept out of the feature phases
until unblocked.

| ID | Item | Status |
|----|------|--------|
| P5.1 | Meta AI registration for DAT | ⛔ blocked — Meta companion-app bug + free-sideload entitlement stripping |
| P5.2 | "What am I looking at?" vision turns | ⬜ wired in the graph, hidden in UI until P5.1 |
| P5.3 | OCR / read-back workflows on frames | ⬜ after P5.1 |

See [`ios-without-a-mac.md`](ios-without-a-mac.md) and the risk notes in
[`roadmap.md`](roadmap.md) for the sideloading/registration constraints.

---

## Cross-cutting / ongoing ⬜

- **Reliability:** keep the reconnect/backoff + audio-interruption handling green as features grow.
- **Cost control:** the Responses-API calls (web search, follow-ups) add spend; add metering + a per-feature on/off setting.
- **Tab consolidation:** the app now has 7 tabs (Assistant, Workspaces, Skills, Knowledge, Notes, Recordings, Patch Notes). Consider merging Notes + Knowledge into a single "Library" tab to reduce the iOS "More" overflow.
- **Testing:** extend the unit suite as stores/tools evolve; add UI smoke tests once the tab set stabilizes.

---

## Suggested sequencing

1. **Phase 2** next — pure on-device, high daily value, no new infrastructure.
2. **Phase 4** in parallel where cheap (extra skill steps, HA expansion).
3. **Phase 5** whenever Meta registration unblocks (external dependency).
4. **Phase 3** last / when a backend is justified — it's the biggest lift.
