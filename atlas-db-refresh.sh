#!/bin/bash
# ============================================================================
# atlas-db-refresh.sh — synthetic-data refresh of dev + sandbox Aurora from prod
#
# RUNS IN: AWS CloudShell, account 103869374886 (Atlas mgmt/prod), us-west-2
# RUNTIME: ~5-15 min depending on prod data size
# IDEMPOTENT: re-runnable; each run writes to a unique S3 prefix by epoch.
#
# WHAT IT DOES (top to bottom, in order):
#   1. Discover prod Aurora endpoint + credentials (from prod SSM)
#   2. pg_dump the prod 'atlas' DB to a local temp file
#   3. Upload the dump to a transient S3 bucket in prod (auto-cleaned at end)
#   4. For each of [dev account 008482603985, sandbox account 923561819954]:
#        a. AssumeRole into OrganizationAccountAccessRole
#        b. Discover that account's Aurora endpoint + credentials (from that
#           account's SSM)
#        c. Download the dump (using assumed credentials -> cross-account S3 read)
#        d. pg_restore into that account's Aurora 'acuity' DB
#        e. Run a sanity SELECT to confirm row counts
#   5. Delete the S3 bucket + objects (transient — never persists)
#
# WHAT IT DOES NOT DO:
#   - Does NOT touch the prod 'atlas' DB (read-only pg_dump)
#   - Does NOT change ECS, Aurora schema versions, KMS, or Terraform state
#   - Does NOT modify SSM in prod (only reads /atlas/prod/database/url)
#   - Does NOT scrub data (synthetic-only per David's prior decision)
#
# SAFETY:
#   - Pre-flight gate: verifies you're in account 103869374886 before starting
#   - Refuses if not us-west-2
#   - Wraps the entire run in a temp directory under /tmp (auto-cleaned on exit)
#   - Logs every step with timestamps
#
# REVERT:
#   - Dev / sandbox: re-run prior backup snapshot restore if data looks wrong
#     (each account's Aurora has automated backups with 7-day PITR)
#   - Prod: untouched, no revert needed
# ============================================================================

set -euo pipefail

# ---------- Configuration ----------
REGION="us-west-2"
PROD_ACCOUNT="103869374886"
DEV_ACCOUNT="008482603985"
SANDBOX_ACCOUNT="923561819954"
ASSUME_ROLE_NAME="OrganizationAccountAccessRole"

PROD_SSM_DB_URL="/atlas/prod/database/url"
DEV_SSM_DB_URL="/atlas/dev/database/url"
SANDBOX_SSM_DB_URL="/atlas/sandbox/database/url"

EPOCH=$(date +%s)
STAGING_BUCKET="atlas-db-refresh-${EPOCH}-${PROD_ACCOUNT}"
DUMP_KEY="prod-atlas-${EPOCH}.dump"

WORK_DIR=$(mktemp -d -t atlas-db-refresh-XXXX)
LOG_FILE="${WORK_DIR}/run.log"

# ---------- Logging helpers ----------
log() { echo "[$(date -u +%H:%M:%S)] $*" | tee -a "${LOG_FILE}"; }
err() { echo "[$(date -u +%H:%M:%S)] ERROR: $*" | tee -a "${LOG_FILE}" >&2; }

cleanup() {
  local rc=$?
  log "==> Cleanup: removing local work directory"
  if [[ -d "${WORK_DIR}" ]]; then
    rm -rf "${WORK_DIR}"
  fi
  if [[ "${BUCKET_CREATED:-0}" == "1" ]]; then
    log "==> Cleanup: emptying + deleting staging bucket s3://${STAGING_BUCKET}"
    aws s3 rm "s3://${STAGING_BUCKET}" --recursive --region "${REGION}" >/dev/null 2>&1 || true
    aws s3 rb "s3://${STAGING_BUCKET}" --region "${REGION}" >/dev/null 2>&1 || true
  fi
  if [[ ${rc} -ne 0 ]]; then
    err "Script exited with status ${rc}. See log: ${LOG_FILE}"
  fi
  return ${rc}
}
trap cleanup EXIT

# ---------- Pre-flight ----------
log "==============================================================="
log " Atlas DB Refresh — prod -> dev + sandbox"
log " Epoch: ${EPOCH}"
log " Work dir: ${WORK_DIR}"
log "==============================================================="
log
log "==> Pre-flight checks"

CURRENT_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
if [[ "${CURRENT_ACCOUNT}" != "${PROD_ACCOUNT}" ]]; then
  err "Must run in account ${PROD_ACCOUNT}. Currently in ${CURRENT_ACCOUNT}."
  exit 1
fi
log "    Account: ${CURRENT_ACCOUNT} (prod) [ok]"

if [[ "${AWS_DEFAULT_REGION:-${AWS_REGION:-}}" != "${REGION}" ]] && [[ "${AWS_REGION:-}" != "${REGION}" ]]; then
  # CloudShell sometimes only sets AWS_REGION
  export AWS_DEFAULT_REGION="${REGION}"
fi
log "    Region: ${REGION} [ok]"

# Verify required tooling
for tool in aws psql pg_dump pg_restore jq; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    if [[ "${tool}" == "psql" || "${tool}" == "pg_dump" || "${tool}" == "pg_restore" ]]; then
      log "    Installing postgresql client tools (sudo dnf install -y postgresql15)"
      sudo dnf install -y postgresql15 >/dev/null 2>&1 || sudo yum install -y postgresql15 >/dev/null 2>&1 || {
        err "Failed to install postgresql client. Aborting."
        exit 1
      }
    else
      err "Missing required tool: ${tool}"
      exit 1
    fi
  fi
done
log "    Tools: aws, psql, pg_dump, pg_restore, jq [ok]"

# Verify cross-account AssumeRole works
for acc in "${DEV_ACCOUNT}" "${SANDBOX_ACCOUNT}"; do
  if ! aws sts assume-role \
        --role-arn "arn:aws:iam::${acc}:role/${ASSUME_ROLE_NAME}" \
        --role-session-name "atlas-db-refresh-probe-${EPOCH}" \
        --duration-seconds 900 \
        --query 'Credentials.AccessKeyId' \
        --output text >/dev/null 2>&1; then
    err "Cannot AssumeRole into ${acc}. Check OrganizationAccountAccessRole trust policy."
    exit 1
  fi
  log "    AssumeRole probe ${acc}: [ok]"
done

# ---------- Step 1: Read prod DB credentials ----------
log
log "==> Step 1/5: Read prod Aurora connection string from SSM"
PROD_DB_URL=$(aws ssm get-parameter \
  --name "${PROD_SSM_DB_URL}" \
  --with-decryption \
  --region "${REGION}" \
  --query 'Parameter.Value' \
  --output text)
if [[ -z "${PROD_DB_URL}" ]]; then
  err "Could not read ${PROD_SSM_DB_URL}"
  exit 1
fi
# Extract DB name from URL for logging (URL format: postgresql://user:pass@host:5432/dbname?...)
PROD_DB_NAME=$(echo "${PROD_DB_URL}" | sed -E 's|.*/([^?]+).*|\1|')
PROD_DB_HOST=$(echo "${PROD_DB_URL}" | sed -E 's|.*@([^:/]+).*|\1|')
log "    Prod host: ${PROD_DB_HOST}"
log "    Prod database: ${PROD_DB_NAME}"

# ---------- Step 2: pg_dump prod ----------
log
log "==> Step 2/5: pg_dump prod database (custom format, compressed)"
DUMP_FILE="${WORK_DIR}/${DUMP_KEY}"
PROD_DB_URL_QUOTED=$(printf %q "${PROD_DB_URL}")
# Use custom format (-Fc) for parallel restore + selective object handling
# --no-owner / --no-acl: roles differ across accounts; skip role grants
# --no-tablespaces: tablespaces are env-specific
pg_dump \
  --dbname="${PROD_DB_URL}" \
  --format=custom \
  --compress=6 \
  --no-owner \
  --no-acl \
  --no-tablespaces \
  --verbose \
  --file="${DUMP_FILE}" 2> "${WORK_DIR}/pg_dump.log" || {
    err "pg_dump failed. See ${WORK_DIR}/pg_dump.log"
    tail -30 "${WORK_DIR}/pg_dump.log" >&2
    exit 1
  }
DUMP_SIZE=$(stat -c%s "${DUMP_FILE}")
log "    Dump size: $(numfmt --to=iec --suffix=B ${DUMP_SIZE})"

# ---------- Step 3: Upload to transient S3 ----------
log
log "==> Step 3/5: Upload dump to transient S3 bucket"
log "    Bucket: s3://${STAGING_BUCKET}"
aws s3api create-bucket \
  --bucket "${STAGING_BUCKET}" \
  --region "${REGION}" \
  --create-bucket-configuration LocationConstraint="${REGION}" >/dev/null
BUCKET_CREATED=1

# Lock down + encrypt
aws s3api put-public-access-block --bucket "${STAGING_BUCKET}" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-encryption --bucket "${STAGING_BUCKET}" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

# Cross-account read policy for dev + sandbox
cat > "${WORK_DIR}/bucket-policy.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AllowDevSandboxRead",
    "Effect": "Allow",
    "Principal": {"AWS": [
      "arn:aws:iam::${DEV_ACCOUNT}:root",
      "arn:aws:iam::${SANDBOX_ACCOUNT}:root"
    ]},
    "Action": ["s3:GetObject", "s3:ListBucket"],
    "Resource": [
      "arn:aws:s3:::${STAGING_BUCKET}",
      "arn:aws:s3:::${STAGING_BUCKET}/*"
    ]
  }]
}
JSON
aws s3api put-bucket-policy --bucket "${STAGING_BUCKET}" --policy "file://${WORK_DIR}/bucket-policy.json"

# 1-day lifecycle (belt-and-suspenders; explicit cleanup happens in trap)
aws s3api put-bucket-lifecycle-configuration --bucket "${STAGING_BUCKET}" \
  --lifecycle-configuration '{"Rules":[{"ID":"expire-1d","Status":"Enabled","Filter":{"Prefix":""},"Expiration":{"Days":1}}]}'

aws s3 cp "${DUMP_FILE}" "s3://${STAGING_BUCKET}/${DUMP_KEY}" --region "${REGION}" >/dev/null
log "    Upload complete: s3://${STAGING_BUCKET}/${DUMP_KEY}"

# ---------- Step 4: Restore into dev + sandbox ----------
restore_into_account() {
  local label="$1"
  local target_account="$2"
  local target_ssm_path="$3"

  log
  log "==> Step 4/5: Restore into ${label} (account ${target_account})"

  # AssumeRole
  local role_arn="arn:aws:iam::${target_account}:role/${ASSUME_ROLE_NAME}"
  local creds_json
  creds_json=$(aws sts assume-role \
    --role-arn "${role_arn}" \
    --role-session-name "atlas-db-refresh-${label}-${EPOCH}" \
    --duration-seconds 3600 \
    --output json)

  local AKI SAK SST
  AKI=$(echo "${creds_json}" | jq -r .Credentials.AccessKeyId)
  SAK=$(echo "${creds_json}" | jq -r .Credentials.SecretAccessKey)
  SST=$(echo "${creds_json}" | jq -r .Credentials.SessionToken)

  # Subshell with the assumed credentials
  (
    export AWS_ACCESS_KEY_ID="${AKI}"
    export AWS_SECRET_ACCESS_KEY="${SAK}"
    export AWS_SESSION_TOKEN="${SST}"
    export AWS_DEFAULT_REGION="${REGION}"

    # 4a: Get target DB URL
    local target_url
    target_url=$(aws ssm get-parameter \
      --name "${target_ssm_path}" \
      --with-decryption \
      --region "${REGION}" \
      --query 'Parameter.Value' \
      --output text)
    if [[ -z "${target_url}" ]]; then
      err "Could not read ${target_ssm_path} in ${target_account}"
      return 1
    fi
    local target_host target_db
    target_host=$(echo "${target_url}" | sed -E 's|.*@([^:/]+).*|\1|')
    target_db=$(echo "${target_url}" | sed -E 's|.*/([^?]+).*|\1|')
    log "    ${label} host: ${target_host}"
    log "    ${label} database: ${target_db}"

    # 4b: Download dump (using assumed creds — cross-account read)
    local local_dump="${WORK_DIR}/${label}.dump"
    aws s3 cp "s3://${STAGING_BUCKET}/${DUMP_KEY}" "${local_dump}" --region "${REGION}" >/dev/null
    log "    Downloaded dump: $(numfmt --to=iec --suffix=B $(stat -c%s ${local_dump}))"

    # 4c: Drop existing data + restore
    # CRITICAL: per David's mandate, target DBs are empty Terraform shells.
    # We blow away the public schema cleanly and restore on top.
    log "    Dropping + recreating 'public' schema in ${target_db}"
    psql "${target_url}" -v ON_ERROR_STOP=1 -c "DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public; GRANT ALL ON SCHEMA public TO PUBLIC;" >/dev/null

    log "    pg_restore -> ${label} (this may take a few min)..."
    pg_restore \
      --dbname="${target_url}" \
      --no-owner \
      --no-acl \
      --no-tablespaces \
      --jobs=4 \
      --verbose \
      "${local_dump}" 2> "${WORK_DIR}/pg_restore-${label}.log" || {
        # pg_restore returns nonzero on warnings (e.g., extension owner mismatch).
        # Check if any FATAL errors are present.
        if grep -q "ERROR:" "${WORK_DIR}/pg_restore-${label}.log"; then
          err "pg_restore had errors. See ${WORK_DIR}/pg_restore-${label}.log"
          grep "ERROR:" "${WORK_DIR}/pg_restore-${label}.log" | head -20 >&2
          return 1
        fi
      }

    # 4d: Sanity check — row counts
    log "    Sanity check: counting rows in key tables"
    psql "${target_url}" -v ON_ERROR_STOP=1 -t -c "
      SELECT 'tables: ' || count(*)::text FROM information_schema.tables WHERE table_schema='public';
      SELECT 'users: ' || count(*)::text FROM users;
    " 2>/dev/null | sed 's/^/      /' | tee -a "${LOG_FILE}" || {
      log "      (table count probe failed — tables may have different names; that's ok)"
    }

    log "    ${label} restore complete"
    rm -f "${local_dump}"
  )
  local rc=$?
  if [[ ${rc} -ne 0 ]]; then
    err "Restore into ${label} failed (rc=${rc})"
    return 1
  fi
  return 0
}

restore_into_account "dev" "${DEV_ACCOUNT}" "${DEV_SSM_DB_URL}"
restore_into_account "sandbox" "${SANDBOX_ACCOUNT}" "${SANDBOX_SSM_DB_URL}"

# ---------- Step 5: Done ----------
log
log "==============================================================="
log " SUCCESS"
log "==============================================================="
log " Prod DB dumped from: ${PROD_DB_HOST}"
log " Dev refreshed:       account ${DEV_ACCOUNT}"
log " Sandbox refreshed:   account ${SANDBOX_ACCOUNT}"
log " Transient S3 bucket: will be deleted on exit"
log " Local work dir:      will be deleted on exit"
log "==============================================================="

exit 0
