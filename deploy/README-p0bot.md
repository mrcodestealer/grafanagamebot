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

## Prerequisites / gotchas

- **Ollama** running on the server with the model pulled: `ollama pull qwen3.6:35b-a3b`.
  The service user must reach `P0_QA_OLLAMA_URL` (default `http://localhost:11434`).
- **Lark console → Events & Callbacks →** subscription mode **"Use long connection"**,
  subscribe to event **`im.message.receive_v1`**. Do NOT also set a Request URL.
- **Scopes** (add + publish a version): `im:message`, `wiki:wiki:readonly`,
  `docx:document:readonly`. Then **share the wiki space/doc with the app**, or it can't read it.
- `python3 -m venv` needs `python3-venv` (`sudo apt install python3-venv`) on Debian/Ubuntu.
- Startup logs `p0 bot open_id=ou_…` — optionally set that as `P0_BOT_OPEN_ID` in `.env`
  for the most reliable group @-mention detection (DMs and `/ask` work without it).
