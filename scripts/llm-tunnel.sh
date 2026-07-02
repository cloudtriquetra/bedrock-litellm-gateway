#!/usr/bin/env bash
# Open (or close) an SSH tunnel to a remote litellm-proxy instance, so a
# local OpenAI-compatible client can reach http://localhost:<port>/v1
# without the proxy ever being exposed on a public interface.
#
# Usage:
#   ./llm-tunnel.sh start --host ubuntu@1.2.3.4 --key ~/.ssh/id.pem [--local-port 4000] [--remote-port 4000]
#   ./llm-tunnel.sh status
#   ./llm-tunnel.sh stop
#
# Config persists across start/status/stop via a small state file, so you
# only need to pass --host/--key on `start`.
set -euo pipefail

STATE_DIR="${LLM_TUNNEL_STATE_DIR:-$HOME/.cache/bedrock-litellm-gateway}"
PIDFILE="${STATE_DIR}/tunnel.pid"
CONFFILE="${STATE_DIR}/tunnel.conf"

action="${1:-}"
shift || true

HOST=""
KEY=""
LOCAL_PORT=4000
REMOTE_PORT=4000

while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --key) KEY="$2"; shift 2 ;;
    --local-port) LOCAL_PORT="$2"; shift 2 ;;
    --remote-port) REMOTE_PORT="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

mkdir -p "$STATE_DIR"

case "$action" in
  start)
    if [ -z "$HOST" ] || [ -z "$KEY" ]; then
      if [ -f "$CONFFILE" ]; then
        # shellcheck disable=SC1090
        source "$CONFFILE"
      else
        echo "usage: $0 start --host user@ip --key /path/to/key.pem [--local-port N] [--remote-port N]" >&2
        exit 1
      fi
    fi
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      echo "[llm-tunnel] already running (pid $(cat "$PIDFILE"))"
      exit 0
    fi
    cat > "$CONFFILE" << EOF
HOST="${HOST}"
KEY="${KEY}"
LOCAL_PORT="${LOCAL_PORT}"
REMOTE_PORT="${REMOTE_PORT}"
EOF
    ssh -i "$KEY" -N -L "${LOCAL_PORT}:127.0.0.1:${REMOTE_PORT}" "$HOST" &
    echo $! > "$PIDFILE"
    up=0
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      sleep 1
      # A bare TCP connect check — this script doesn't know your master_key,
      # so it can't hit /v1/models with auth. curl -sf on an unauthenticated
      # request against a running proxy still returns (401, not connection
      # refused), which is enough to prove the tunnel itself is up.
      if curl -s -o /dev/null "http://localhost:${LOCAL_PORT}/v1/models"; then
        up=1
        break
      fi
    done
    if [ "$up" -eq 1 ]; then
      echo "[llm-tunnel] up on localhost:${LOCAL_PORT} (pid $(cat "$PIDFILE"))"
    else
      echo "[llm-tunnel] tunnel started but nothing answered on localhost:${LOCAL_PORT} after 10s" >&2
      echo "[llm-tunnel] check the proxy service is running on the remote host" >&2
      exit 1
    fi
    ;;
  stop)
    if [ -f "$PIDFILE" ]; then
      kill "$(cat "$PIDFILE")" 2>/dev/null || true
      rm -f "$PIDFILE"
      echo "[llm-tunnel] stopped"
    else
      echo "[llm-tunnel] no tunnel pidfile found"
    fi
    ;;
  status)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      echo "[llm-tunnel] running (pid $(cat "$PIDFILE"))"
    else
      echo "[llm-tunnel] not running"
    fi
    ;;
  *)
    echo "usage: $0 {start|stop|status} [--host user@ip --key /path/to/key.pem]" >&2
    exit 1
    ;;
esac
