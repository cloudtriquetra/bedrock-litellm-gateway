#!/usr/bin/env bash
# Install a LiteLLM OpenAI-compatible proxy in front of Amazon Bedrock, as a
# systemd service. Run this ON the host that has Bedrock IAM permissions
# (ideally via an instance role — no AWS keys are handled by this script).
#
# Usage:
#   AWS_REGION=us-east-1 \
#   BEDROCK_MODEL_ID=global.anthropic.claude-opus-4-6-v1 \
#   MODEL_NAME=claude-opus-4-6 \
#   PROXY_PORT=4000 \
#   ./install.sh
#
# Don't know your inference profile ID yet? Run
# ./list-available-models.sh <region> first.
set -euo pipefail

AWS_REGION="${AWS_REGION:?set AWS_REGION, e.g. us-east-1}"
BEDROCK_MODEL_ID="${BEDROCK_MODEL_ID:?set BEDROCK_MODEL_ID, e.g. global.anthropic.claude-opus-4-6-v1}"
MODEL_NAME="${MODEL_NAME:-claude-opus-4-6}"
PROXY_PORT="${PROXY_PORT:-4000}"
RUN_USER="${RUN_USER:-$(whoami)}"
HOME_DIR="${HOME_DIR:-$HOME}"

echo "[install] region=${AWS_REGION} model=${BEDROCK_MODEL_ID} name=${MODEL_NAME} port=${PROXY_PORT}"

# 1. uv + a pinned Python 3.12 — sidesteps distros that ship a Python too
#    new for LiteLLM's Rust-based deps (orjson via PyO3). See
#    docs/troubleshooting.md if you hit a PyO3 build error.
if ! command -v uv >/dev/null 2>&1; then
  echo "[install] installing uv..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi
export PATH="${HOME_DIR}/.local/bin:${PATH}"

uv python install 3.12

# 2. venv + litellm proxy + boto3
VENV_DIR="${HOME_DIR}/litellm-proxy"
if [ -d "$VENV_DIR" ]; then
  echo "[install] reusing existing venv at ${VENV_DIR}"
else
  uv venv --python 3.12 "$VENV_DIR"
fi
# shellcheck disable=SC1091
source "${VENV_DIR}/bin/activate"
uv pip install 'litellm[proxy]' boto3 -q

# 3. sanity check: confirm the model/profile is actually invokable BEFORE
#    wiring it into the proxy — fail fast with a clear diagnostic instead of
#    a confusing 500 from the proxy later.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! python3 "${SCRIPT_DIR}/test-invoke.py" "$AWS_REGION" "$BEDROCK_MODEL_ID"; then
  echo "[install] test-invoke failed — see docs/troubleshooting.md before proceeding." >&2
  echo "[install] not writing proxy config for a model that doesn't work yet." >&2
  exit 1
fi

# 4. proxy config
CONFIG_DIR="${HOME_DIR}/litellm-proxy-config"
mkdir -p "$CONFIG_DIR"
if [ -f "${CONFIG_DIR}/config.yaml" ]; then
  echo "[install] ${CONFIG_DIR}/config.yaml already exists — leaving it alone."
  echo "[install] add a model_list entry manually (see config/litellm-config.example.yaml) and re-run this script's systemd steps if needed."
else
  MASTER_KEY="sk-$(openssl rand -hex 24)"
  cat > "${CONFIG_DIR}/config.yaml" << EOF
model_list:
  - model_name: ${MODEL_NAME}
    litellm_params:
      model: bedrock/${BEDROCK_MODEL_ID}
      aws_region_name: ${AWS_REGION}

general_settings:
  master_key: ${MASTER_KEY}
EOF
  echo "[install] wrote ${CONFIG_DIR}/config.yaml"
  echo "[install] MASTER KEY (save this — it's your api_key): ${MASTER_KEY}"
fi

# 5. systemd service
UNIT_PATH="/etc/systemd/system/litellm-proxy.service"
sudo bash -c "sed \
  -e 's|__RUN_USER__|${RUN_USER}|g' \
  -e 's|__HOME__|${HOME_DIR}|g' \
  -e 's|__PROXY_PORT__|${PROXY_PORT}|g' \
  '${SCRIPT_DIR}/../systemd/litellm-proxy.service.template' > '${UNIT_PATH}'"

sudo systemctl daemon-reload
sudo systemctl enable litellm-proxy
sudo systemctl restart litellm-proxy

# LiteLLM can take several seconds to finish startup (model registration,
# etc.) before it's actually listening — poll instead of a fixed sleep.
up=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  sleep 1
  if curl -sf "http://127.0.0.1:${PROXY_PORT}/v1/models" \
      -H "Authorization: Bearer $(grep master_key "${CONFIG_DIR}/config.yaml" | awk '{print $2}')" \
      > /dev/null; then
    up=1
    break
  fi
done
if [ "$up" -eq 1 ]; then
  echo "[install] proxy is up on 127.0.0.1:${PROXY_PORT}"
else
  echo "[install] proxy did not respond after 15s — check: sudo journalctl -u litellm-proxy -n 50" >&2
  exit 1
fi

echo "[install] done. See README.md for how to reach this from a remote client."
