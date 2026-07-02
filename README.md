# bedrock-litellm-gateway

Turn Amazon Bedrock's Claude models into a standard OpenAI-compatible
`/v1/chat/completions` + `/v1/models` endpoint, so any harness/tool built
against `base_url` + `api_key` (the OpenAI SDK shape) can use Bedrock without
knowing anything about SigV4, `InvokeModel`, or inference profiles.

Bedrock does **not** natively expose an OpenAI-compatible API — this repo
runs [LiteLLM](https://github.com/BerriAI/litellm) as a translation proxy on
a host with Bedrock IAM permissions (an EC2 instance role, or any AWS
credential source), and documents two Bedrock gotchas that commonly block
newer Claude models from working at all.

```
your app (OpenAI-shaped client)
   │  http://<host>:4000/v1
   ▼
LiteLLM proxy (systemd service)
   │  boto3 → bedrock-runtime, SigV4 via instance role / AWS credentials
   ▼
Amazon Bedrock — anthropic.claude-* via cross-region inference profile
```

## Why you probably need this

If you tried calling a Claude model on Bedrock directly with the bare model
ID (`anthropic.claude-opus-4-6-v1`) and got:

```
ValidationException: Invocation of model ID anthropic.claude-opus-4-6-v1
with on-demand throughput isn't supported. Retry your request with the ID
or ARN of an inference profile that contains this model.
```

— that's Bedrock's on-demand throughput restriction. Newer Claude models are
often only invokable through a **cross-region inference profile**
(`global.anthropic.claude-opus-4-6-v1`, `us.anthropic.claude-...`, etc.),
not the bare model ID. The Bedrock console Playground applies this for you
automatically, which is why a model can "work in the Playground" but fail
via direct API calls with the bare ID. See [docs/troubleshooting.md](docs/troubleshooting.md)
for how to find the right profile ID and diagnose this vs. the next issue.

If instead you got:

```
AccessDeniedException: anthropic.claude-opus-4-8 is not available for
this account.
```

— that's a **separate, per-model entitlement** in the Bedrock console
(Model access page), independent of IAM. `AmazonBedrockFullAccess` only
grants permission to *call* the API; it does not grant access to any
specific model. Newer/frontier models are frequently gated separately from
older ones you already have access to — having `claude-opus-4-6` working
does not mean `claude-opus-4-8` will. Request access per model in
Console → Bedrock → Model access, per region.

## Quick start

Requires: an AWS credential source with `bedrock:InvokeModel` /
`bedrock:ListFoundationModels` / `bedrock:ListInferenceProfiles` permission
(an EC2 instance role is the easiest — no keys to manage), and a Linux host
to run the proxy on (tested on Ubuntu).

```bash
git clone https://github.com/cloudtriquetra/bedrock-litellm-gateway
cd bedrock-litellm-gateway

# Discover which Claude models + inference profiles you actually have
# access to in your account/region:
./scripts/list-available-models.sh us-east-1

# Install uv + a pinned Python + litellm, write the proxy config, and
# register a systemd service. Edit the variables at the top of the script
# first (region, model, port), or override via env vars.
AWS_REGION=us-east-1 \
BEDROCK_MODEL_ID=global.anthropic.claude-opus-4-6-v1 \
PROXY_PORT=4000 \
./scripts/install.sh
```

The install script prints the generated `master_key` — save it, it's your
`api_key` for the OpenAI-compatible client. It's also written to
`~/litellm-proxy-config/config.yaml` on the host (never committed to git).

Point any OpenAI-compatible client at it:

```bash
curl http://<host>:4000/v1/chat/completions \
  -H "Authorization: Bearer <master_key>" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-opus-4-6","messages":[{"role":"user","content":"ping"}],"max_tokens":16}'
```

## Reaching it from elsewhere (no public port)

The proxy binds to `127.0.0.1` on the host by default — nothing is exposed
to the internet, and no security group / firewall changes are required. If
your client runs somewhere else (your laptop, another host), forward the
port over SSH instead of opening it:

```bash
./scripts/llm-tunnel.sh start --host ubuntu@<your-ec2-ip> --key ~/.ssh/your-key.pem
./scripts/llm-tunnel.sh status
./scripts/llm-tunnel.sh stop
```

## Why Python 3.12, not whatever ships on your distro

LiteLLM depends on `orjson`, which is a Rust extension built via PyO3.
PyO3's stable-ABI support lags new CPython releases by months — on very
recent distro images (e.g. Ubuntu 26.04 shipping Python 3.14 by default)
`pip install litellm` fails with:

```
error: the configured Python interpreter version (3.14) is newer than
PyO3's maximum supported version (0.23.3)
```

`install.sh` uses [`uv`](https://github.com/astral-sh/uv) to fetch a pinned
Python 3.12 into an isolated venv, sidestepping the system Python entirely
— no `apt`/PPA wrangling, no risk to system packages.

## Adding more models

Edit `~/litellm-proxy-config/config.yaml` on the host, add a `model_list`
entry (see `config/litellm-config.example.yaml` for the shape), then:

```bash
sudo systemctl restart litellm-proxy
```

Only add a model here once you've confirmed it's actually invokable — run
`scripts/list-available-models.sh <region>` first, then test the specific
model/profile ID with `scripts/test-invoke.py` before wiring it into the
proxy config. Don't guess inference profile IDs.

## Repo layout

| Path | What it is |
|---|---|
| `scripts/install.sh` | Installs uv + Python 3.12 + LiteLLM, writes config, registers systemd service |
| `scripts/list-available-models.sh` | Lists Anthropic foundation models + inference profiles actually available in your account/region |
| `scripts/test-invoke.py` | Direct `bedrock-runtime.invoke_model` smoke test — bypasses LiteLLM, useful for isolating access-vs-proxy issues |
| `scripts/llm-tunnel.sh` | SSH port-forward helper for reaching the proxy from a remote client |
| `config/litellm-config.example.yaml` | Template proxy config — copy and edit, never commit the real one (it holds `master_key`) |
| `systemd/litellm-proxy.service.template` | systemd unit template used by `install.sh` |
| `docs/troubleshooting.md` | The inference-profile vs. model-access distinction, with real error text to grep for |

## What this repo does not do

- Doesn't manage AWS credentials — relies on whatever credential source is
  already available on the host (instance role strongly recommended).
- Doesn't open any inbound network access — the proxy is `127.0.0.1`-only
  by design; use `llm-tunnel.sh` or your own network setup to reach it.
- Doesn't request Bedrock model access on your behalf — that's a manual
  step in the AWS console (see Why you probably need this, above).
