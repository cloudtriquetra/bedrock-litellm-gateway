#!/usr/bin/env bash
# List Anthropic foundation models AND cross-region inference profiles
# available in the given Bedrock region, using whatever AWS credentials are
# already active (instance role, ~/.aws/credentials, env vars, etc.).
#
# Usage: ./list-available-models.sh <region>
set -euo pipefail

REGION="${1:?usage: $0 <aws-region>}"

if ! python3 -c "import boto3" 2>/dev/null; then
  echo "boto3 not found in the current Python environment." >&2
  echo "Run this from the venv created by install.sh, or: pip install boto3" >&2
  exit 1
fi

python3 - "$REGION" << 'PY'
import sys
import boto3

region = sys.argv[1]
c = boto3.client("bedrock", region_name=region)

print(f"=== Anthropic foundation models offered in {region} ===")
print("(this lists what the REGION offers, not what your ACCOUNT is entitled to use)")
resp = c.list_foundation_models(byProvider="anthropic")
for m in resp["modelSummaries"]:
    status = m.get("modelLifecycle", {}).get("status", "?")
    print(f"  {m['modelId']:55s} {status}")

print()
print(f"=== System-defined cross-region inference profiles (Claude) in {region} ===")
resp = c.list_inference_profiles(typeEquals="SYSTEM_DEFINED")
found = False
for p in resp["inferenceProfileSummaries"]:
    if "claude" in p["inferenceProfileId"].lower():
        found = True
        print(f"  {p['inferenceProfileId']:55s} {p['status']}")
if not found:
    print("  (none found)")

print()
print("Neither list above tells you whether invocation will actually succeed —")
print("that depends on per-model Model Access entitlement. Test with:")
print(f"  python3 scripts/test-invoke.py {region} <model-or-profile-id>")
PY
