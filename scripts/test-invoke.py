#!/usr/bin/env python3
"""Direct bedrock-runtime.invoke_model smoke test — bypasses LiteLLM
entirely, so you can tell apart a proxy problem from an underlying Bedrock
access problem. See docs/troubleshooting.md for how to read the errors.

Usage: python3 test-invoke.py <region> <model-or-inference-profile-id>
"""
import json
import sys

import boto3


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <region> <model-or-inference-profile-id>", file=sys.stderr)
        return 2

    region, model_id = sys.argv[1], sys.argv[2]
    rt = boto3.client("bedrock-runtime", region_name=region)
    body = json.dumps(
        {
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": 16,
            "messages": [{"role": "user", "content": "Reply with the single word: pong"}],
        }
    )

    print(f"Invoking {model_id!r} in {region}...")
    try:
        resp = rt.invoke_model(modelId=model_id, body=body)
        payload = json.loads(resp["body"].read())
        text = payload["content"][0]["text"]
        print(f"OK: {text!r}")
        return 0
    except Exception as e:  # noqa: BLE001 - deliberately broad, this is a diagnostic tool
        msg = str(e)
        print(f"FAIL: {msg}")
        if "on-demand throughput" in msg:
            print(
                "\nThis model needs an inference profile ID, not the bare model ID.\n"
                "Run scripts/list-available-models.sh to find one, then retry with that."
            )
        elif "is not available for this account" in msg:
            print(
                "\nThis is a Model Access entitlement gap, not an IAM or code problem.\n"
                "Request access in AWS Console -> Bedrock -> Model access, for this exact "
                "model and region."
            )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
