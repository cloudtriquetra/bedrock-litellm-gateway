# Troubleshooting

## Two failure modes that look similar but aren't

Bedrock model access has two independent gates. Conflating them wastes time
— here's how to tell them apart from the error text alone.

### 1. `ValidationException` — wrong model ID shape (inference profile required)

```
ValidationException: Invocation of model ID anthropic.claude-opus-4-6-v1
with on-demand throughput isn't supported. Retry your request with the ID
or ARN of an inference profile that contains this model.
```

**Meaning:** the model exists and you have access to it, but on-demand
invocation isn't offered for that model — you must invoke through a
cross-region inference profile instead of the bare model ID.

**Fix:** find the profile ID and use that as the model ID.

```bash
python3 -c "
import boto3
c = boto3.client('bedrock', region_name='<your-region>')
resp = c.list_inference_profiles(typeEquals='SYSTEM_DEFINED')
for p in resp['inferenceProfileSummaries']:
    if 'claude' in p['inferenceProfileId'].lower():
        print(p['inferenceProfileId'], '|', p['status'])
"
```

Profile IDs are typically prefixed by geography: `global.`, `us.`, `eu.`,
`apac.`, etc. Not every model has every prefix — check what's actually
listed rather than assuming. Use the *profile ID* (or its ARN) as the
`modelId` in `invoke_model`, and as the `model:` value in LiteLLM's config
(`bedrock/<profile-id>`).

### 2. `AccessDeniedException` — no entitlement for this model

```
AccessDeniedException: anthropic.claude-opus-4-8 is not available for
this account. You can explore other available models on Amazon Bedrock.
```

**Meaning:** IAM permissions are fine (you're allowed to call
`InvokeModel`), but your account hasn't been granted access to *this
specific model*. This is true even if the model shows up as `ACTIVE` in
`list_foundation_models` — that call lists what's *offered in the region*,
not what your account is *entitled to use*.

**Fix:** AWS Console → Bedrock → **Model access** → request access for the
specific model, in the specific region you're calling. Important
non-obvious details:

- Access is granted **per model, per region** — having `claude-opus-4-6`
  access does not carry over to `claude-opus-4-8`, `claude-sonnet-5`, or
  `claude-fable-5`. Each needs its own request.
- Approval can be instant or can require additional use-case justification,
  especially for the newest/most capable models.
- There's no API call that reliably tells you "is my account entitled to
  invoke this model" other than actually trying `invoke_model` and reading
  the error — `list_foundation_models` won't tell you.

### Diagnosing which one you're hitting

Run `scripts/test-invoke.py <region> <model-or-profile-id>` — it calls
`bedrock-runtime.invoke_model` directly (no LiteLLM in the loop) and prints
the raw exception. Match against the two patterns above.

If you're getting `AccessDeniedException` on a bare model ID, request
access first — you'll then likely hit the `ValidationException` for
newer models, at which point you switch to the inference profile ID and
it should work (assuming access was actually granted).

## LiteLLM install fails building `orjson` (Rust/PyO3 error)

```
error: the configured Python interpreter version (3.14) is newer than
PyO3's maximum supported version. Current version: 0.23.3
```

Your system Python is too new for `orjson`'s prebuilt wheels / PyO3's
stable ABI ceiling (this hit Ubuntu 26.04, which ships Python 3.14 by
default). Don't fight this with `PYO3_USE_ABI3_FORWARD_COMPATIBILITY=1` —
it's unreliable. Instead, install a pinned older Python via `uv` and build
the venv against that:

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
uv python install 3.12
uv venv --python 3.12 ~/litellm-proxy
source ~/litellm-proxy/bin/activate
uv pip install 'litellm[proxy]' boto3
```

`scripts/install.sh` does this automatically.

## Proxy starts but `/v1/models` / `/v1/chat/completions` returns nothing / times out

Check the systemd service actually came up and is listening:

```bash
sudo systemctl status litellm-proxy --no-pager
sudo journalctl -u litellm-proxy -n 50 --no-pager
ss -tlnp | grep 4000
```

If the process is running but the port isn't bound yet, LiteLLM can take a
few seconds to finish startup after `systemctl start` — give it 5-10s
before testing. `scripts/llm-tunnel.sh` retries the health check for up to
10 seconds for this reason; don't reduce that if you're scripting around
this.

## `curl` to `localhost:4000` works on the host but not from my laptop

Expected — the proxy binds to `127.0.0.1` on the host by design, so nothing
listens on the host's external interface. Use `scripts/llm-tunnel.sh` (SSH
`-L` port-forward) rather than opening a security group rule. If you do
want direct external access instead, that's a deliberate choice outside
what this repo sets up — you'd need to bind LiteLLM to `0.0.0.0`, open the
security group to specific source IPs only, and put TLS in front of it
(the `master_key` alone is not a substitute for TLS on a public port).
