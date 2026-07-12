#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# /whotalk hybrid local-ASR setup: ffmpeg + sherpa-onnx + SenseVoiceSmall model.
#
#   sudo bash /root/p0bot/deploy/setup-whotalk-asr.sh
#
# Overridable:
#   APP_DIR=/root/p0bot                                  # bot directory
#   PY_BIN=/root/miniconda3/envs/p0bot/bin/python        # the python the service runs with
#   MODEL_URL=<tarball url>                              # SenseVoice tarball override
#
# After it succeeds: set P0_WHOTALK_ASR_ENABLE=1 in .env and restart p0bot.
# Also required once: console scope minutes:minutes.media:export (add + publish),
# keep it in P0_VC_OAUTH_SCOPES, and have the owner re-run /vcauth -> /vccode.
# ---------------------------------------------------------------------------
set -uo pipefail

APP_DIR="${APP_DIR:-/root/p0bot}"
PY_BIN="${PY_BIN:-/root/miniconda3/envs/p0bot/bin/python}"
MODEL_DIR="$APP_DIR/models/sensevoice"
# int8 tarball (~155 MB download, model.int8.onnx 228M) — the 2024-07-17 build supports
# punctuation via use_itn (the newer 2025-09-09 one does not), so pin this version.
MODEL_URL="${MODEL_URL:-https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2}"

echo "==> whotalk ASR setup: APP_DIR=$APP_DIR PY_BIN=$PY_BIN"
[ -x "$PY_BIN" ] || { echo "FATAL: PY_BIN '$PY_BIN' not executable — pass PY_BIN=<service python>"; exit 1; }

# 1) python deps (the wheel bundles onnxruntime; no torch needed)
echo "==> pip install sherpa-onnx numpy"
"$PY_BIN" -m pip install -q --upgrade sherpa-onnx numpy || {
  echo "WARN: pip install failed — retrying with aliyun mirror"
  "$PY_BIN" -m pip install -q -i https://mirrors.aliyun.com/pypi/simple/ --upgrade sherpa-onnx numpy
}
"$PY_BIN" - <<'PY' || { echo "FATAL: sherpa_onnx/numpy not importable"; exit 1; }
import numpy, sherpa_onnx
print("deps OK: sherpa-onnx", getattr(sherpa_onnx, "__version__", "?"))
PY

# 2) ffmpeg
if command -v ffmpeg >/dev/null 2>&1 || [ -x "$APP_DIR/bin/ffmpeg" ]; then
  echo "==> ffmpeg already present"
else
  echo "==> installing ffmpeg (package manager, then static-build fallback)"
  (command -v dnf >/dev/null 2>&1 && dnf install -y ffmpeg) \
    || (command -v yum >/dev/null 2>&1 && yum install -y ffmpeg) \
    || (command -v apt-get >/dev/null 2>&1 && apt-get install -y ffmpeg) \
    || true
  if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "==> package ffmpeg unavailable — downloading static build"
    mkdir -p "$APP_DIR/bin"
    tmp="$(mktemp -d)"
    curl -fL --retry 3 -o "$tmp/ffmpeg.tar.xz" \
      "https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz" \
      && tar -xJf "$tmp/ffmpeg.tar.xz" -C "$tmp" \
      && cp "$tmp"/ffmpeg-*-static/ffmpeg "$APP_DIR/bin/ffmpeg" \
      && chmod +x "$APP_DIR/bin/ffmpeg" \
      && echo "==> static ffmpeg -> $APP_DIR/bin/ffmpeg (auto-detected by the bot)"
    rm -rf "$tmp"
  fi
fi
{ command -v ffmpeg >/dev/null 2>&1 || [ -x "$APP_DIR/bin/ffmpeg" ]; } \
  || { echo "FATAL: ffmpeg still missing"; exit 1; }

# 3) SenseVoice model
if [ -f "$MODEL_DIR/tokens.txt" ] && { [ -f "$MODEL_DIR/model.int8.onnx" ] || [ -f "$MODEL_DIR/model.onnx" ]; }; then
  echo "==> model already present in $MODEL_DIR"
else
  echo "==> downloading SenseVoice model (~155 MB)"
  mkdir -p "$MODEL_DIR"
  tmp="$(mktemp -d)"
  curl -fL --retry 3 -o "$tmp/model.tar.bz2" "$MODEL_URL" || { echo "FATAL: model download failed"; exit 1; }
  tar -xjf "$tmp/model.tar.bz2" -C "$tmp" || { echo "FATAL: extract failed"; exit 1; }
  src="$(find "$tmp" -maxdepth 1 -mindepth 1 -type d | head -1)"
  for f in model.int8.onnx model.onnx tokens.txt; do
    [ -f "$src/$f" ] && cp "$src/$f" "$MODEL_DIR/$f"
  done
  rm -rf "$tmp"
  [ -f "$MODEL_DIR/tokens.txt" ] || { echo "FATAL: tokens.txt missing after extract"; exit 1; }
  { [ -f "$MODEL_DIR/model.int8.onnx" ] || [ -f "$MODEL_DIR/model.onnx" ]; } \
    || { echo "FATAL: model onnx missing after extract"; exit 1; }
  echo "==> model installed -> $MODEL_DIR"
fi

# 4) smoke test: load the recognizer once
echo "==> smoke test (loads the model once)"
MODEL_DIR="$MODEL_DIR" "$PY_BIN" - <<'PY' || { echo "FATAL: recognizer failed to load"; exit 1; }
import os, sherpa_onnx
d = os.environ["MODEL_DIR"]
model = os.path.join(d, "model.int8.onnx")
if not os.path.isfile(model):
    model = os.path.join(d, "model.onnx")
r = sherpa_onnx.OfflineRecognizer.from_sense_voice(
    model=model, tokens=os.path.join(d, "tokens.txt"), num_threads=2, use_itn=True, language="auto")
print("recognizer OK:", model)
PY

echo
echo "-----------------------------------------------------------------------"
echo "DONE. Next steps:"
echo "  1. Console: add scope minutes:minutes.media:export + PUBLISH a version"
echo "  2. Ensure it is in P0_VC_OAUTH_SCOPES, then owner re-runs /vcauth -> /vccode"
echo "  3. sed -i 's/^P0_WHOTALK_ASR_ENABLE=.*/P0_WHOTALK_ASR_ENABLE=1/' $APP_DIR/.env"
echo "     (or add the line), then: systemctl restart p0bot"
echo "  4. /whotalk — the fetched message should say 来源/source: 本地识别 local ASR"
echo "-----------------------------------------------------------------------"
