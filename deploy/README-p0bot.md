# p0bot — server deployment

p0bot runs from `main.py` in this repo, gated behind `P0_DOC_QA_ENABLE=1`. It uses a
**long connection (WebSocket)**, so it needs **no public URL / no open port**
(`ENABLE_HTTP=0`). It can safely run on the same server as the Grafana monitoring bot
because it binds nothing.

## 1. Pull the code onto the server

```bash
# first time
sudo git clone https://github.com/mrcodestealer/grafanagamebot.git /opt/p0bot
# later, to update
sudo git -C /opt/p0bot pull origin main
```

## 2. One-shot setup (venv + deps + systemd unit)

```bash
sudo bash /opt/p0bot/deploy/setup-p0bot.sh
```

This creates `/opt/p0bot/venv`, installs `flask requests lark-oapi`, and installs
`/etc/systemd/system/p0bot.service`. Re-running it also does `git pull` + `daemon-reload`
(handy as your update command).

Override paths/user if needed:
```bash
sudo APP_DIR=/opt/p0bot RUN_USER=root bash /opt/p0bot/deploy/setup-p0bot.sh
```

## 3. Create the env file (holds the secret — never committed)

```bash
sudo nano /opt/p0bot/.env      # paste the p0bot env block, then save
sudo chmod 600 /opt/p0bot/.env
```

Minimum required keys: `APP_ID`, `APP_SECRET`, `LARK_HOST=https://open.larksuite.com`,
`LARK_EVENT_MODE=ws`, `ENABLE_HTTP=0`, `P0_DOC_QA_ENABLE=1`, `P0_WIKI_URL=…`. See
`.env.example` in the repo root for the full template.

## 4. Enable + start

```bash
sudo systemctl enable --now p0bot
sudo systemctl restart p0bot
sudo systemctl status p0bot
journalctl -u p0bot -f          # watch: "Lark WebSocket client starting", "p0 doc loaded: nodes=…"
```

## 5. Update loop (what you asked for)

```bash
sudo git -C /opt/p0bot pull origin main && sudo systemctl restart p0bot
```

## Group members ("/members") — the easy "who's in it"

Lists who is in the **chat group** (not a video call). In any group the bot is a member of,
send **`/members`** → it posts a card of everyone in the group (names + count, bots excluded).

Needs only scope **`im:chat:readonly`** (add + publish in the Developer Console) and the bot
to be **added to the group** — no admin role, no OAuth, uses the bot's own token. On by default
(`P0_MEMBERS_ENABLE=1`). Error `232011` in the card means the bot isn't in that group yet.

This is distinct from meeting attendance below: `/members` = chat-group membership (works);
`/meeting` = video-call participants (admin-only, usually blocked).

## Meeting attendance (optional, Mode C)

A bot **cannot join a call** and **cannot read a meeting it doesn't own** — so there's no
"who's in this link" for arbitrary meetings. Mode C is an **on-demand attendance report**:
in chat, `/meeting <meeting-number-or-link>` → the bot pulls the participant report for that
9-digit meeting number and posts a card. It works for **ongoing** meetings (who's in now,
🟢) and **ended** meetings (who attended, with join→leave times); participant names are
included by the API.

Enable in `.env`: `P0_MEETING_ENABLE=1` (optional `P0_MEETING_TRIGGER`, `P0_MEETING_LOOKBACK_HOURS`).
Use it: DM the bot `/meeting 123456789`, or in a group `@p0bot /meeting <link>`.

**Permission (the catch):** the report API `GET /open-apis/vc/v1/participant_list` returns
`121005` for the bot's tenant token — it requires the **caller** to hold the admin
**"Video Conferencing · Meeting Management"** role. So p0bot uses an **admin's user token via
OAuth**. One-time setup:

1. Developer Console → your app → add scope `vc:rooms.room.detailinfo:read` (+ the contact
   name scopes), and in **Security → Redirect URLs** register the exact `P0_VC_REDIRECT_URI`
   (default `http://localhost:5088/oauth/callback` — it doesn't need to be reachable).
2. In chat, an **admin who holds the Meeting-Management role** runs **`/vcauth`** → the bot
   replies with a login link → the admin opens it, consents → the browser lands on the
   redirect (may fail to load — fine) → the admin copies `code=…` from the address bar and
   sends **`/vccode <code>`** (or pastes the whole redirected URL).
3. The bot stores + auto-refreshes that admin's token (needs `offline_access`, included by
   default) and uses it for `/meeting`. Re-auth only if the refresh token expires (~30d/365d cap).

If `/meeting` shows a `NO_AUTH` card, run `/vcauth` first. Look-back window is capped at 24h.

## Prerequisites / gotchas

- **Ollama** running on the server with the model pulled: `ollama pull qwen3.6:35b-a3b`.
  The service user must reach `P0_QA_OLLAMA_URL` (default `http://localhost:11434`).
- **Lark console → Events & Callbacks →** subscription mode **"Use long connection"**,
  subscribe to event **`im.message.receive_v1`**. Do NOT also set a Request URL.
- **Scopes** (add + publish a version): `im:message`, `wiki:wiki:readonly`,
  `docx:document:readonly`. Then **share the wiki space/doc with the app**, or it can't read it.
- **Reactions**: p0bot reacts 👌 (`P0_REACT_ACK_EMOJI=OK`) while Qwen is thinking and ✅
  (`P0_REACT_DONE_EMOJI=DONE`) when the answer is sent — in DMs and on group @-mentions.
  Reactions use the `im:message` scope (already granted for sending), so no extra scope is
  needed. `OK`/`DONE` are valid Lark emoji keys. Best-effort — a failure just skips the
  reaction, the answer still sends. Disable with `P0_REACT_ENABLE=0`.
- `python3 -m venv` needs `python3-venv` (`sudo apt install python3-venv`) on Debian/Ubuntu.
- Startup logs `p0 bot open_id=ou_…` — optionally set that as `P0_BOT_OPEN_ID` in `.env`
  for the most reliable group @-mention detection (DMs and `/ask` work without it).
