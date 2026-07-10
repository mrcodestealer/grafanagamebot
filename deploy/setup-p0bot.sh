#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# p0bot server setup / updater. Run on the Linux server as root (or via sudo).
#
#   First time:  sudo bash deploy/setup-p0bot.sh
#   Updates:     sudo bash /opt/p0bot/deploy/setup-p0bot.sh   (git pull + deps + reload)
#
# Overridable via env, e.g.:  sudo APP_DIR=/srv/p0bot RUN_USER=lark bash deploy/setup-p0bot.sh
# ---------------------------------------------------------------------------
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/p0bot}"
REPO_URL="${REPO_URL:-https://github.com/mrcodestealer/grafanagamebot.git}"
RUN_USER="${RUN_USER:-root}"
SERVICE_NAME="p0bot"
PYTHON_BIN="${PYTHON_BIN:-python3}"

echo "==> p0bot setup: APP_DIR=$APP_DIR RUN_USER=$RUN_USER"

# 1) clone or update the repo
if [ -d "$APP_DIR/.git" ]; then
  echo "==> updating existing checkout"
  git -C "$APP_DIR" pull origin main
else
  echo "==> cloning $REPO_URL"
  mkdir -p "$(dirname "$APP_DIR")"
  git clone "$REPO_URL" "$APP_DIR"
fi

# 2) python venv + dependencies (flask, requests, lark-oapi is all p0bot needs)
if [ ! -x "$APP_DIR/venv/bin/python" ]; then
  echo "==> creating venv (needs python3-venv on Debian/Ubuntu)"
  "$PYTHON_BIN" -m venv "$APP_DIR/venv"
fi
"$APP_DIR/venv/bin/pip" install --quiet --upgrade pip
"$APP_DIR/venv/bin/pip" install --quiet flask requests lark-oapi
echo "==> deps installed"

# 3) install/refresh the systemd unit (substitute paths + user)
UNIT_SRC="$APP_DIR/deploy/p0bot.service"
UNIT_DST="/etc/systemd/system/${SERVICE_NAME}.service"
sed -e "s#/opt/p0bot#${APP_DIR}#g" -e "s#^User=root#User=${RUN_USER}#" \
  "$UNIT_SRC" > "$UNIT_DST"
systemctl daemon-reload
echo "==> installed $UNIT_DST"

# 4) make sure ownership + .env perms are sane if .env already exists
if [ "$RUN_USER" != "root" ]; then
  chown -R "$RUN_USER":"$RUN_USER" "$APP_DIR" || true
fi
if [ -f "$APP_DIR/.env" ]; then
  chmod 600 "$APP_DIR/.env" || true
fi

echo
echo "-----------------------------------------------------------------------"
if [ ! -f "$APP_DIR/.env" ]; then
  echo "NEXT: create $APP_DIR/.env (paste the p0bot env), then:"
else
  echo ".env present. To (re)start:"
fi
echo "  sudo systemctl enable --now ${SERVICE_NAME}"
echo "  sudo systemctl restart ${SERVICE_NAME}"
echo "  journalctl -u ${SERVICE_NAME} -f     # watch it connect + load the doc"
echo "-----------------------------------------------------------------------"
