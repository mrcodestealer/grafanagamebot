#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# p0bot server setup / updater. Run on the Linux server as root (or via sudo).
#
#   First time:  sudo bash deploy/setup-p0bot.sh
#   Updates:     sudo bash /opt/p0bot/deploy/setup-p0bot.sh   (git pull + deps + reload)
#
# Overridable via env, e.g.:  sudo APP_DIR=/srv/p0bot RUN_USER=lark bash deploy/setup-p0bot.sh
#   PYTHON_BIN=/root/anaconda3/bin/python   # force a specific interpreter
#   PIP_INDEX=https://mirrors.aliyun.com/pypi/simple/   # force a pip index for base deps
#
# NOTE: intentionally does NOT use `set -e` — a dependency hiccup must not stop
# the systemd unit from being installed, so `systemctl restart p0bot` still works.
#
# lark-oapi is pinned to v1.7.1 (this code targets the SDK's v1.x API, NOT the
# v2_main default branch). If your host's default pip index lacks lark-oapi
# (common on curated internal mirrors) but GitHub is reachable, it is installed
# from source with --no-deps and its deps come from the working index.
# ---------------------------------------------------------------------------
set -uo pipefail

APP_DIR="${APP_DIR:-/opt/p0bot}"
REPO_URL="${REPO_URL:-https://github.com/mrcodestealer/grafanagamebot.git}"
RUN_USER="${RUN_USER:-root}"
SERVICE_NAME="p0bot"
PYCHECK='import flask, requests, lark_oapi'
GIT_LARK="git+https://github.com/larksuite/oapi-sdk-python.git@v1.7.1"

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

# 2) pick a Python interpreter that already has the deps; else build a venv + install.
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
    "$BASE_PY" -m venv "$APP_DIR/venv" || echo "WARN: venv creation failed (install python3-venv?)"
  fi
  VPY="$APP_DIR/venv/bin/python"
  if [ -x "$VPY" ]; then
    "$VPY" -m pip install --upgrade pip >/dev/null 2>&1 || true

    # a) common deps — pure/allowlisted packages most internal mirrors already carry
    BASE_DEPS=(flask requests requests_toolbelt pycryptodome websockets httpx)
    echo "==> installing base deps: ${BASE_DEPS[*]}"
    if ! "$VPY" -m pip install "${BASE_DEPS[@]}"; then
      for idx in "${PIP_INDEX:-}" https://mirrors.aliyun.com/pypi/simple/ https://pypi.org/simple/; do
        [ -n "$idx" ] || continue
        echo "==> retry base deps via $idx"
        "$VPY" -m pip install -i "$idx" "${BASE_DEPS[@]}" && break
      done
    fi

    # b) lark-oapi — index if present, else GitHub source (v1.7.1) with --no-deps
    if ! "$VPY" -c "import lark_oapi" >/dev/null 2>&1; then
      echo "==> installing lark-oapi (index -> GitHub source v1.7.1 --no-deps)"
      "$VPY" -m pip install lark-oapi >/dev/null 2>&1 \
        || "$VPY" -m pip install --no-deps "$GIT_LARK" \
        || "$VPY" -m pip install --no-deps --no-build-isolation "$GIT_LARK"
    fi
    PY="$VPY"
  fi
fi

# 3) verify the chosen interpreter can import everything
DEP_OK=0
if [ -n "$PY" ] && "$PY" -c "$PYCHECK" >/dev/null 2>&1; then
  DEP_OK=1
  echo "==> deps OK with: $PY"
else
  echo "WARN: deps (flask requests lark-oapi) NOT importable with '$PY'."
  echo "      Install manually then re-run this script:"
  echo "        $PY -m pip install flask requests requests_toolbelt pycryptodome websockets httpx"
  echo "        $PY -m pip install --no-deps '$GIT_LARK'"
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
