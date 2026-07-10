#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# p0bot server setup / updater. Run on the Linux server as root (or via sudo).
#
#   First time:  sudo bash deploy/setup-p0bot.sh
#   Updates:     sudo bash /opt/p0bot/deploy/setup-p0bot.sh   (git pull + deps + reload)
#
# Overridable via env, e.g.:  sudo APP_DIR=/srv/p0bot RUN_USER=lark bash deploy/setup-p0bot.sh
#   PYTHON_BIN=/root/anaconda3/bin/python   # force a specific interpreter
#   PIP_INDEX=https://pypi.org/simple/      # force a pip index for the venv fallback
#
# NOTE: intentionally does NOT use `set -e` — a dependency hiccup must not stop
# the systemd unit from being installed, so `systemctl restart p0bot` still works.
# ---------------------------------------------------------------------------
set -uo pipefail

APP_DIR="${APP_DIR:-/opt/p0bot}"
REPO_URL="${REPO_URL:-https://github.com/mrcodestealer/grafanagamebot.git}"
RUN_USER="${RUN_USER:-root}"
SERVICE_NAME="p0bot"
DEPS="flask requests lark-oapi"
PYCHECK='import flask, requests, lark_oapi'

echo "==> p0bot setup: APP_DIR=$APP_DIR RUN_USER=$RUN_USER"

# 1) clone or update the repo
if [ -d "$APP_DIR/.git" ]; then
  echo "==> updating existing checkout"
  git -C "$APP_DIR" pull origin main || echo "WARN: git pull failed (continuing with current checkout)"
else
  echo "==> cloning $REPO_URL"
  mkdir -p "$(dirname "$APP_DIR")"
  git clone "$REPO_URL" "$APP_DIR" || { echo "FATAL: git clone failed"; exit 1; }
fi

# 2) pick a Python interpreter that has the deps; else build a venv and install them.
PY=""
for cand in "${PYTHON_BIN:-}" python python3 /opt/anaconda3/bin/python /root/anaconda3/bin/python; do
  [ -n "$cand" ] || continue
  if command -v "$cand" >/dev/null 2>&1 && "$cand" -c "$PYCHECK" >/dev/null 2>&1; then
    PY="$(command -v "$cand")"
    echo "==> using existing interpreter that already has the deps: $PY"
    break
  fi
done

if [ -z "$PY" ]; then
  echo "==> no interpreter has the deps yet — building a venv"
  BASE_PY="${PYTHON_BIN:-python3}"
  if [ ! -x "$APP_DIR/venv/bin/python" ]; then
    "$BASE_PY" -m venv "$APP_DIR/venv" || echo "WARN: venv creation failed (need python3-venv?)"
  fi
  VPY="$APP_DIR/venv/bin/python"
  if [ -x "$VPY" ]; then
    "$VPY" -m pip install --quiet --upgrade pip || true
    installed=""
    for idx in "${PIP_INDEX:-}" "" "https://pypi.org/simple/" "https://mirrors.aliyun.com/pypi/simple/" "https://pypi.tuna.tsinghua.edu.cn/simple/"; do
      if [ -n "$idx" ]; then
        echo "==> pip install via index: $idx"
        "$VPY" -m pip install --quiet -i "$idx" $DEPS && installed=1 && break
      else
        echo "==> pip install via default index"
        "$VPY" -m pip install --quiet $DEPS && installed=1 && break
      fi
    done
    PY="$VPY"
  fi
fi

# 3) verify the chosen interpreter can import everything
DEP_OK=0
if [ -n "$PY" ] && "$PY" -c "$PYCHECK" >/dev/null 2>&1; then
  DEP_OK=1
  echo "==> deps OK with: $PY"
else
  echo "WARN: dependencies (flask requests lark-oapi) are NOT importable with '$PY'."
  echo "      Install them manually, e.g.:"
  echo "        $PY -m pip install -i https://mirrors.aliyun.com/pypi/simple/ $DEPS"
  echo "      then: sudo systemctl restart $SERVICE_NAME"
  [ -n "$PY" ] || PY="$APP_DIR/venv/bin/python"
fi

# 4) install/refresh the systemd unit, pointing ExecStart at the chosen interpreter
UNIT_SRC="$APP_DIR/deploy/p0bot.service"
UNIT_DST="/etc/systemd/system/${SERVICE_NAME}.service"
sed -e "s#/opt/p0bot#${APP_DIR}#g" \
    -e "s#^User=root#User=${RUN_USER}#" \
    -e "s#^ExecStart=.*#ExecStart=${PY} ${APP_DIR}/main.py#" \
    "$UNIT_SRC" > "$UNIT_DST"
systemctl daemon-reload
echo "==> installed $UNIT_DST"
echo "    ExecStart=${PY} ${APP_DIR}/main.py"

# 5) ownership + .env perms
if [ "$RUN_USER" != "root" ]; then
  chown -R "$RUN_USER":"$RUN_USER" "$APP_DIR" 2>/dev/null || true
fi
[ -f "$APP_DIR/.env" ] && chmod 600 "$APP_DIR/.env" 2>/dev/null || true

echo
echo "-----------------------------------------------------------------------"
[ "$DEP_OK" = 1 ] && echo "deps: OK" || echo "deps: MISSING (install manually, see WARN above)"
if [ ! -f "$APP_DIR/.env" ]; then
  echo "NEXT: create $APP_DIR/.env (paste the p0bot env), chmod 600, then:"
else
  echo "NEXT:"
fi
echo "  sudo systemctl enable --now ${SERVICE_NAME}"
echo "  sudo systemctl restart ${SERVICE_NAME}"
echo "  journalctl -u ${SERVICE_NAME} -f     # watch it connect + load the doc"
echo "-----------------------------------------------------------------------"
