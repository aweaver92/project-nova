# Nova Bridge

A small service you run on your dev machine so the **Nova iOS app** can:

- run **Claude Code** tasks (edit files, run commands) — `run_claude_code`
- drive **Cursor** agents — `push_to_cursor`, `list_cursor_sessions`

The iOS app ships the *client*; this is the *server* it talks to.

## Wire contract

All JSON, `Authorization: Bearer <token>` on every request.

| Method | Path | Body | Purpose |
|--------|------|------|---------|
| `POST` | `/claude-code` | `{ "prompt": string, "cwd"?: string }` | Run Claude Code headlessly |
| `POST` | `/cursor/command` | `{ "command": string, "sessionId"?: string }` | Send a prompt to a Cursor agent |
| `GET`  | `/cursor/sessions` | — | List local Cursor agents |
| `GET`  | `/health` | — | Liveness (no auth) |

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

Then say *"Nova, let me talk to Claude"* and give it a coding task, or ask Nova to
run a Claude Code / Cursor command directly.

(Config precedence in the app: in-app Settings → `NOVA_BRIDGE_URL` / `NOVA_BRIDGE_TOKEN`
env → `NovaBridgeBaseURL` / `NovaBridgeToken` in `Secrets.xcconfig`.)

## Notes & limits

- **60-second phone timeout.** The shipped app aborts a bridge call after ~60s. The
  server keeps working (Claude's edits still land), but you may not hear the final
  result for long tasks. Scope prompts small, or check results in your editor.
- **Security.** The bearer token is the only gate. Keep `NOVA_BRIDGE_TOKEN` secret and
  prefer Tailscale (private) over a public tunnel.
- **`/cursor/*`** use the Cursor SDK's local runtime against `NOVA_BRIDGE_WORKDIR`.
  `push_to_cursor` with a `sessionId` resumes that agent; without one it creates a new
  local agent. `list_cursor_sessions` lists local agents.
