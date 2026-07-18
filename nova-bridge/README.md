# Nova Bridge

A small service you run on your dev machine so the **Nova iOS app** can:

- run **Claude Code** tasks (edit files, run commands) — `run_claude_code`
- drive **Cursor** agents — `push_to_cursor`, `list_cursor_sessions`
- mint short-lived **OpenAI Realtime** secrets so the voice assistant works
  without baking the OpenAI key into the app — `POST /realtime/token`

The iOS app ships the *client*; this is the *server* it talks to.

## Wire contract

All JSON unless noted, `Authorization: Bearer <token>` on every request.

| Method | Path | Body | Purpose |
|--------|------|------|---------|
| `POST` | `/realtime/token` | `{ "model"?: string }` | Mint a short-lived OpenAI Realtime secret → `{ "value", "expires_at" }` |
| `POST` | `/claude-code` | `{ "prompt": string, "cwd"?: string }` | Run Claude Code headlessly |
| `POST` | `/cursor/command` | `{ "command": string, "sessionId"?: string }` | Blocking Cursor send (legacy; Coding tab prefers `/cursor/runs`) |
| `POST` | `/cursor/runs` | `{ "command": string, "sessionId"?: string, "cwd"?: string, "images"?: [{ "data", "mimeType", "width"?, "height"? }] }` | **SSE** stream of a Cursor run, with optional base64 screenshots |
| `POST` | `/cursor/runs/:runId/cancel` | — | Best-effort cancel of an in-flight run |
| `GET`  | `/cursor/sessions` | — | List local Cursor agents |
| `GET`  | `/cursor/sessions/:id/messages` | — | Transcript history for a session |
| `GET`  | `/preview` | — | Active live previews (with phone-reachable URLs) |
| `POST` | `/preview/start` | `{ "repoId": string }` | Serve the repo on a LAN port (static or `npm run dev`) |
| `POST` | `/preview/stop` | `{ "repoId": string }` | Stop the repo's preview server |
| `GET`  | `/health` | — | Liveness (no auth) |

### Live preview (`/preview/*`)

Lets the phone's browser open whatever Claude/Cursor generated. The bridge
detects the project type: no `package.json` dev script → in-process static
server; `vite`/`next` → spawns `npm run dev` bound to `0.0.0.0` (running
`npm install` first when `node_modules` is missing). Dev servers start
asynchronously — poll `GET /preview` until `state` is `ready`, then open
`url` in Safari. Preview ports (default 8790–8799) are unauthenticated by
design; they serve only project content on your LAN.

### SSE events (`POST /cursor/runs`)

Each event is one `data: {json}\n\n` line. Types:

- `assistant_delta` — `{ "type", "text" }`
- `thinking_delta` — `{ "type", "text" }`
- `tool_start` / `tool_end` — `{ "type", "name", "summary"?, "path"?, "diff"? }`
- `activity` — `{ "type", "phase", "text", "detail"?, "done"? }` (live process feed)
- `status` — `{ "type", "status" }`
- `error` — `{ "type", "error" }`
- `done` — `{ "type", "sessionId", "runId", "status", "result" }`

Image prompts accept up to four JPEG, PNG, or WebP images (3 MB each, 8 MB
total). Nova resizes screenshots on-device and sends them as native Cursor SDK
image content, so the model can read visible errors and UI state directly.

Smoke-test a streaming run:

```bash
curl -N -X POST localhost:8787/cursor/runs \
  -H "Authorization: Bearer $NOVA_BRIDGE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"command":"say hello in one sentence"}'
```

Fetch history after you have a `sessionId` from `done`:

```bash
curl localhost:8787/cursor/sessions/$SESSION_ID/messages \
  -H "Authorization: Bearer $NOVA_BRIDGE_TOKEN"
```

Smoke-test the Realtime token mint (needs `OPENAI_API_KEY` in `.env`):

```bash
curl -X POST localhost:8787/realtime/token \
  -H "Authorization: Bearer $NOVA_BRIDGE_TOKEN" \
  -H "Content-Type: application/json" -d '{}'
# → {"ok":true,"value":"ek_...","expires_at":...,"model":"gpt-realtime"}
```

## Prerequisites

- **Node.js 20+**
- **Claude Code CLI** on your PATH — verify with `claude --version` (see Anthropic's install docs). Only needed for `/claude-code`.
- **Cursor API key** for the Cursor endpoints — https://cursor.com/dashboard/integrations
- **Tailscale** (recommended) for a secure HTTPS URL your phone can reach.

## 1. Install & configure

```bash
cd nova-bridge
npm install
cp .env.example .env
```

Edit `.env`:

- `NOVA_BRIDGE_TOKEN` — a long random secret. You'll paste the **same** value into the app.
- `CURSOR_API_KEY` — your Cursor key (only for the Cursor endpoints).
- `OPENAI_API_KEY` — your OpenAI key. Required for the voice assistant: the app mints
  short-lived Realtime secrets through `/realtime/token` instead of embedding this key.
- `NOVA_BRIDGE_WORKDIR` — default project directory for tasks (optional; defaults to where you launch it).
- `CLAUDE_ARGS` — to let Claude Code edit files unattended, set e.g. `--permission-mode acceptEdits` (or `--dangerously-skip-permissions`, broader — use with care).

Generate a token:

```bash
node -e "console.log(require('crypto').randomBytes(24).toString('hex'))"
```

## 2. Run it

```bash
npm run start   # or: npm run dev  (auto-reload)
```

You should see `Nova Bridge listening on http://0.0.0.0:8787`.

Smoke-test locally:

```bash
curl localhost:8787/health

curl -X POST localhost:8787/claude-code \
  -H "Authorization: Bearer $NOVA_BRIDGE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"prompt":"list the files in this repo"}'
```

## 3. Expose it over HTTPS (Tailscale)

The iOS app blocks plain `http://` by default (App Transport Security), so give it an **HTTPS** URL. Tailscale keeps it private to your devices — no public exposure.

1. Install Tailscale on the **Mac** and the **iPhone**; log both into the same tailnet.
2. On the Mac, publish the bridge over your tailnet with HTTPS:

```bash
tailscale serve --bg 8787
tailscale serve status   # shows the https URL
```

This gives a URL like `https://your-mac.tailnet-name.ts.net/`.

> Prefer a quick throwaway tunnel instead? `ngrok http 8787` also works and returns an `https://…ngrok…` URL. (Public — rely on the bearer token.)

## 4. Point the app at it

In Nova → **Agents** tab → **Claude — Nova Bridge**:

- **URL:** the HTTPS URL from step 3 (e.g. `https://your-mac.tailnet-name.ts.net`)
- **Bridge token:** the same `NOVA_BRIDGE_TOKEN` from your `.env`
- Tap **Save bridge settings**

Then open the **Coding** tab (visible while Claude is the active agent) to attach a
Cursor session by id, type prompts, and watch the live SSE preview. Or say
*"Nova, let me talk to Claude"* and give it a coding task — voice `push_to_cursor`
uses the same pinned session id as the Coding tab.

(Config precedence in the app: in-app Settings → `NOVA_BRIDGE_URL` / `NOVA_BRIDGE_TOKEN`
env → `NovaBridgeBaseURL` / `NovaBridgeToken` in `Secrets.xcconfig`.)

## Notes & limits

- **60-second phone timeout.** The shipped app aborts a bridge call after ~60s. The
  server keeps working (Claude's edits still land), but you may not hear the final
  result for long tasks. Scope prompts small, or check results in your editor.
- **Security.** The bearer token is the only gate. Keep `NOVA_BRIDGE_TOKEN` secret and
  prefer Tailscale (private) over a public tunnel.
- **`/cursor/*`** use the Cursor SDK's local runtime against `NOVA_BRIDGE_WORKDIR`.
  `push_to_cursor` / `/cursor/command` with a `sessionId` resumes that agent; without one
  it creates a new local agent. Prefer **`POST /cursor/runs`** (SSE) for the Coding tab
  so the phone can preview progress without waiting for the full blocking response.
  `list_cursor_sessions` lists local agents; `GET /cursor/sessions/:id/messages` loads
  transcript history.
