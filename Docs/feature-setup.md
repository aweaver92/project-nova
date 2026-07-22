# Feature setup — what Nova needs to work

Newer Nova features often need a key, token, or a running bridge before they do anything useful. This guide lists **where to put each secret** and what else must be true.

For bridge install, Tailscale, and full env reference, see [`nova-bridge/README.md`](../nova-bridge/README.md) and [`nova-bridge/.env.example`](../nova-bridge/.env.example).

---

## Quick checklist

| Feature | Where to configure | What you need |
|--------|--------------------|---------------|
| **OpenAI org spend** | Settings → **OpenAI spend** | Org **Admin** API key (`sk-admin-…`) |
| **Ultrahuman Ring readiness** | Training → toolbar **Ring** → **Ring API** | Ultrahuman personal API token |
| **Coding (Cursor, Plan mode, repos)** | Settings → **Nova Bridge** + PC `nova-bridge/.env` | Bridge URL, matching token, `CURSOR_API_KEY` |
| **Voice Listen (Realtime)** | Bridge `OPENAI_API_KEY` (preferred) | Same bridge URL/token; project OpenAI key on the PC |
| **Home Assistant tools** | Build-time Secrets / env (no Settings UI) | `NOVA_HA_BASE_URL` + `NOVA_HA_TOKEN` |
| **GitHub clone / PRs** | PC: `gh auth login` or bridge `GH_TOKEN` | `git` + `gh` on the bridge machine |

---

## 1. OpenAI spend (Admin costs)

**What it does:** Charts this calendar month’s **organization** spend by line item (Admin Costs API).

**Where to put the key (in the app):**

1. Open **Settings**
2. Scroll to **OpenAI spend**
3. Paste an OpenAI **Admin** API key into the secure field (`sk-admin-…`)
4. Tap **Save Admin key**, then **Refresh**

**Important:**

- Use an **org Admin** key (`sk-admin-…`), **not** a project key (`sk-…`). Project keys get 401/403 on `/v1/organization/costs`.
- Stored on-device in Keychain (`com.unifiedesign.Nova.openai.admin`). Not sent through nova-bridge.
- Separate from bridge `OPENAI_API_KEY` (that key is for Realtime voice mint only).

**Privacy toggles** for cost-related behavior live under Settings → **Cost & privacy** (they do not replace the Admin key).

---

## 2. Ultrahuman Ring readiness

**What it does:** Training hub readiness strip + Max tool `ring_readiness` (Partner daily metrics).

**Where to put the token:**

1. Open the **Training** tab
2. Tap **Ring** in the toolbar
3. In the **Ring API** sheet, paste your Ultrahuman personal API token
4. Tap **Save token**

Get a token from [vision.ultrahuman.com](https://vision.ultrahuman.com) developer docs. Stored in Keychain (`com.unifiedesign.Nova.ultrahuman`). No bridge required.

---

## 3. Nova Bridge (Coding, Plan mode, voice mint, repos)

Most coding features need the PC bridge reachable and authenticated.

### On the phone

**Settings → Nova Bridge**

1. Set **Bridge URL** (e.g. Tailscale or LAN address)
2. Paste **Bridge token** — must match `NOVA_BRIDGE_TOKEN` in `nova-bridge/.env`
3. Tap **Save & run setup check**
4. Use **Bridge setup** rows to confirm Cursor, Realtime, git, `gh`, and repo roots

### On the PC (`nova-bridge/.env`)

Copy from `.env.example`, then set at least:

| Variable | Needed for |
|----------|------------|
| `NOVA_BRIDGE_TOKEN` | App ↔ bridge auth (paste into Settings) |
| `CURSOR_API_KEY` | Coding tab, Plan mode, `push_to_cursor` |
| `OPENAI_API_KEY` | Voice Listen ephemeral tokens (`POST /realtime/token`) |
| `NOVA_REPO_ROOTS` | Repo discovery / Coding workspaces |
| `GH_TOKEN` or `GITHUB_TOKEN` | Optional; else run `gh auth login` on the PC |

**Restart nova-bridge after any `.env` change** (env is loaded once at process start).

```powershell
cd nova-bridge
npm run start
# or: npm run watchdog:install
```

### Plan mode (Approve & build)

1. Bridge running with current Cursor stream code + `CURSOR_API_KEY`
2. Coding tab → mode **Plan** → send a prompt
3. When CreatePlan finishes, use the **Plan ready** card: **Approve & build** or **Modify plan**

No extra API key in the app for Plan mode—only a live bridge.

---

## 4. Voice Listen (OpenAI Realtime)

**Preferred path:** Bridge has `OPENAI_API_KEY`; phone has Settings → Nova Bridge URL + token. The app mints a short-lived `ek_…` via the bridge.

**Dev alternatives** (no bridge mint):

- Bake `OPENAI_API_KEY` via `Nova/Config/Secrets.xcconfig` (from `Secrets.example.xcconfig`)
- Simulator env: `NOVA_OPENAI_API_KEY` / `OPENAI_API_KEY`
- Debug stub: `NOVA_OPENAI_STUB_TOKEN` (see [`Nova/README.md`](../Nova/README.md))

ChatGPT Plus does **not** cover these API calls.

---

## 5. Home Assistant / Find my phone (build-time)

These are **not** configured in Settings:

| Need | How |
|------|-----|
| Home Assistant | `NOVA_HA_BASE_URL` + `NOVA_HA_TOKEN`, or Info.plist / Secrets (`HomeAssistantBaseURL`, `HomeAssistantToken`) |
| Find-my phone number | `NOVA_FIND_MY_PHONE_NUMBER` or Info.plist `NovaFindMyPhoneNumber` |

See [`Docs/ios-without-a-mac.md`](ios-without-a-mac.md) and `Nova/Config/Secrets.example.xcconfig`.

---

## Key inventory (don’t mix these up)

| Secret | Where it lives | Used for |
|--------|----------------|----------|
| OpenAI **Admin** `sk-admin-…` | App Settings → OpenAI spend (Keychain) | Org spend chart |
| OpenAI **project** `sk-…` | Bridge `.env` `OPENAI_API_KEY` (or baked Secrets) | Realtime voice |
| Ultrahuman personal token | Training → Ring API (Keychain) | Ring readiness |
| `NOVA_BRIDGE_TOKEN` | Bridge `.env` **and** Settings → Nova Bridge | All bridge APIs |
| `CURSOR_API_KEY` | Bridge `.env` only | Cursor Coding / Plan |

---

## Related docs

- [`nova-bridge/README.md`](../nova-bridge/README.md) — install, Tailscale, SSE, health checks
- [`Nova/README.md`](../Nova/README.md) — iOS module map + Debug stubs
- [`Docs/ios-without-a-mac.md`](ios-without-a-mac.md) — IPA / SideStore / baked secrets
