#!/bin/bash
# ============================================================================
# Atlas broker v3 deploy — ONE-TIME CloudShell paste
#
# WHAT THIS DOES (idempotent, safe to re-run):
#  1. Discover the IAM role attached to `atlas-ops-broker` Lambda
#  2. Attach inline policy `AtlasBootstrapAssumeRole` granting sts:AssumeRole
#     to the 3 cross-account OrganizationAccountAccessRole ARNs (dev, sandbox, vault)
#  3. Download prod-broker-v3.py from public GitHub
#  4. Zip it and update the `atlas-ops-broker` Lambda function code
#  5. Verify by invoking the new `assume_role_probe` command
#
# WHAT THIS DOES NOT DO:
#  - Does NOT touch prod data
#  - Does NOT modify any dev / sandbox / vault account resources
#  - Does NOT change anything until you actually paste this in CloudShell
#  - Snapshot / share / restore operations happen LATER, driven by the broker
#    autonomously after this v3 is live
#
# REVERT: Lambda keeps prior versions automatically. To roll back:
#   aws lambda update-function-code --function-name atlas-ops-broker \
#     --s3-bucket <prior-deploy-bucket-or-cached-zip>
# Or just re-deploy v2 from the same repo (prod-broker.py).
# ============================================================================

set -euo pipefail

REGION="us-west-2"
FN="atlas-ops-broker"
RAW_URL="https://raw.githubusercontent.com/acuitysystems/atlas-broker-autonomy/main/prod-broker-v3.py"

echo "==> Step 1/5: Discover IAM role attached to ${FN}"
ROLE_ARN=$(aws lambda get-function-configuration \
  --function-name "${FN}" \
  --region "${REGION}" \
  --query 'Role' --output text)
ROLE_NAME="${ROLE_ARN##*/}"
echo "    Role: ${ROLE_NAME}"
echo "    ARN:  ${ROLE_ARN}"

echo
echo "==> Step 2/5: Attach AtlasBootstrapAssumeRole inline policy"
cat > /tmp/atlas-assume-policy.json <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AssumeIntoOrgAccounts",
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": [
        "arn:aws:iam::008482603985:role/OrganizationAccountAccessRole",
        "arn:aws:iam::923561819954:role/OrganizationAccountAccessRole",
        "arn:aws:iam::561789489247:role/OrganizationAccountAccessRole"
      ]
    }
  ]
}
JSON

aws iam put-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-name "AtlasBootstrapAssumeRole" \
  --policy-document file:///tmp/atlas-assume-policy.json
echo "    AtlasBootstrapAssumeRole attached."

echo
echo "==> Step 3/5: Download prod-broker-v3.py from GitHub"
WORK=$(mktemp -d)
cd "${WORK}"
curl -fsSL "${RAW_URL}" -o lambda_function.py
LINES=$(wc -l < lambda_function.py)
echo "    Downloaded ${LINES} lines from ${RAW_URL}"
# Sanity check: must contain BROKER_VERSION 2026-06-25-v3
if ! grep -q '2026-06-25-v3' lambda_function.py; then
  echo "ERROR: downloaded file does not contain expected version marker. Aborting."
  exit 1
fi

echo
echo "==> Step 4/5: Zip and update Lambda function code"
zip -q lambda_function.zip lambda_function.py
aws lambda update-function-code \
  --function-name "${FN}" \
  --region "${REGION}" \
  --zip-file fileb://lambda_function.zip \
  --no-cli-pager \
  --output table \
  --query '{Function:FunctionName,LastModified:LastModified,CodeSha256:CodeSha256,State:State,LastUpdateStatus:LastUpdateStatus}' || true

echo "    Waiting for Lambda update to finish..."
aws lambda wait function-updated --function-name "${FN}" --region "${REGION}"
echo "    Lambda update complete."

echo
echo "==> Step 5/5: Verify cross-account AssumeRole works"
aws lambda invoke \
  --function-name "${FN}" \
  --region "${REGION}" \
  --cli-binary-format raw-in-base64-out \
  --payload '{"command":"health","args":{}}' \
  /tmp/health.json > /dev/null
echo "--- health ---"
cat /tmp/health.json | python3 -m json.tool

echo
aws lambda invoke \
  --function-name "${FN}" \
  --region "${REGION}" \
  --cli-binary-format raw-in-base64-out \
  --payload '{"command":"assume_role_probe","args":{}}' \
  /tmp/probe.json > /dev/null
echo "--- assume_role_probe (all non-mgmt accounts) ---"
cat /tmp/probe.json | python3 -m json.tool

echo
echo "============================================================"
echo "DONE."
echo "Expected: health shows version 2026-06-25-v3, allowed_accounts = 4 entries."
echo "Expected: assume_role_probe shows ok:true for 008482603985, 923561819954, 561789489247."
echo "If any account shows ok:false with AccessDenied — that account's"
echo "OrganizationAccountAccessRole trust policy does not yet allow assume from 103869374886."
echo "Fix: in that account, edit OrganizationAccountAccessRole trust to allow this account."
echo "============================================================"
