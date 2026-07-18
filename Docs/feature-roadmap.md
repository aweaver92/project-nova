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

## Phase 2 — Proactivity & smarter memory ✅ (shipped)

Make Nova feel less like a command line and more like an assistant that
remembers and anticipates. All on-device (plus the existing Responses API for
summarization); no new infrastructure.

| ID | Item | What shipped |
|----|------|--------------|
| P2.1 | Memory compaction / summarization | `FileMemoryDigestStore` (per-workspace durable digest + coverage watermark), `OpenAIMemorySummarizer` (Responses API), `MemoryCompactor` (folds older turns once a threshold is reached). Digest is injected as "Long-term memory for this workspace" ahead of the recent window; compaction runs in the background at session start so it never blocks the live conversation. |
| P2.2 | Semantic knowledge search | `EmbeddingScorer` (Apple `NLEmbedding` mean word vectors, cosine → [0,1]); `KnowledgeSearch` now blends keyword + semantic scores across all sources and falls back to pure keyword when embeddings are unavailable or the query is out-of-vocabulary. |
| P2.3 | Scheduled & proactive skills | `SkillSchedule` (daily or per-weekday time), `SkillScheduler` (repeating `UNCalendarNotificationTrigger`, opt-in permission, namespaced identifiers), `NotificationCoordinator` runs the tapped skill via `orchestrator.runSkill` (deterministic steps always run; spoken confirmation when the stream is open). Schedule editor added to the Skill editor. |
| P2.4 | Spoken follow-ups (toggle) | `UserDefaultsSettingsStore` + Settings tab toggle (default off). When on, Nova offers one suggestion out loud after a reply, with a one-shot guard so the offer never loops. Chips still appear either way. |
| P2.5 | Skill import/export & sharing | `SkillsViewModel.exportJSON` (ShareLink in the editor) / `importJSON` (paste sheet in the Skills tab). Imported skills get a fresh identity so they never overwrite existing ones. |

**Tests:** `Phase2DataTests` (digest store scoping/persistence, compactor threshold & coverage advance, embedding cosine, settings round-trip, skill Codable incl. schedule) and `Phase2DomainTests` (schedule next-fire/trigger components, `runSkill` with/without stream, spoken-follow-up single-offer guard, digest injection).

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

## Phase 4 — Actions & integrations 🟡 (mostly shipped)

Broaden what Nova can *do*, within iOS limits.

| ID | Item | Status / what shipped |
|----|------|-----------------------|
| P4.1 | Automated send (where allowed) | ⛔ deferred / assistive-only — iOS blocks silent send from a sideloaded app without special entitlements; the compose-sheet path (`draft_message` email/text) remains the supported flow. Revisit via Shortcuts automations if the app gains a full provisioning profile. |
| P4.2 | Home Assistant expansion | ✅ `HomeAssistantStateTool` (`home_assistant_state`) reads any entity's state + friendly name + unit for questions like "is the front door locked?"; scenes already work via the existing `home_assistant` tool (`domain:"scene"`). |
| P4.3 | Richer drafting | ✅ `draft_message` now supports a `todo` with a `dueISO` and a new `event` type (title/start/duration → calendar), giving reminder/calendar round-trips from drafts alongside email/text/note. |
| P4.4 | More first-party skill steps | ✅ Added `.webhook` (GET/POST/PUT with optional JSON/text body) and `.delay` (capped wait between steps) skill steps, executed by `SkillRunner` (injectable HTTP caller + sleeper) with editor UI. Conditional/branching steps deferred (the flat step model doesn't branch cleanly yet). |

**Tests:** `Phase4DataTests` — webhook request shaping + failure, capped delay, draft email/event-validation/note routing, HA state summarization.

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

## Cross-cutting / ongoing 🟡

- **Reliability:** ✅ Bridge `/health` surfaces `openaiConfigured` in Settings; Listen warns before mint failure; glasses registration errors include Developer Mode checklist; latency gate + spend estimate in Diagnostics.
- **Cost control:** ✅ Per-feature toggles (web search, follow-ups, visual memory, meetings, local wake word) + retention days + rough UsageMeter estimate.
- **Coding companion v2:** ✅ Working directory binding, spoken Cursor progress (Claude), tool confirmation for Claude Code / Cursor / HA writes, Continue Cursor CTA on Assistant.
- **Skills 2.0:** ✅ Variables (`{{name}}`), conditions, retries, confirmations; built-in Capture → OCR → note skill.
- **Vision unlock:** ✅ `analyze()` awaits correlated transcript; Vision UI when glasses registered; voice vision gated on registration.
- **Tab consolidation:** ✅ power-user shell — five primary tabs (**Assistant**, **Agents**, **Studio**, **Library**, **Media**). Settings is a toolbar sheet (Bridge + Diagnostics + About). Coding is a push destination under Agents when Claude is active. Studio = Workspaces \| Skills; Media = Voice \| Video. Notes + Knowledge remain in Library.
- **Specialist UIs:** ✅ each built-in specialist has a gated Agents destination — Claude **Open Coding**, Max **Open Training**, Sage **Open Wellness**, Remy **Open Kitchen**, Scholar **Open Study** — plus Assistant resume CTAs when that agent is active.
- **Max Training v1:** ✅ Max-exclusive Training hub + live HUD (plans, history, PR strip, set logging, rest countdown); sessions store optional `planId` for next-up progress.
- **Remy Kitchen:** ✅ Enriched pantry, fridge scan, recipes + cook mode, shopping, meal plan, nutrition; voice tools share on-device stores.
- **Testing:** extend the unit suite as stores/tools evolve; add UI smoke tests once the tab set stabilizes.

---

## Suggested sequencing

1. ~~**Phase 2**~~ ✅ done — pure on-device, high daily value, no new infrastructure.
2. ~~**Phase 4**~~ 🟡 mostly done — webhook/delay skill steps, HA state queries, richer drafting. Only P4.1 (silent send) remains, blocked by iOS/sideload limits.
3. **Phase 5** whenever Meta registration unblocks (external dependency).
4. **Phase 3** last / when a backend is justified — it's the biggest lift.
