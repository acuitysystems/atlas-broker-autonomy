#!/bin/bash
# atlas-db-refresh.sh v2 — Full clone prod -> dev + sandbox
# - Source: standalone RDS atlas-acuity-prod-postgres (DB: acuity)
# - Targets: atlas-acuity-dev-aurora (008482603985), atlas-acuity-sandbox-aurora (923561819954)
# - Secrets excluded from data dump: gmail_tokens, prs_credentials (schemas restored, no rows)
# - Auto-discovers all DATABASE_URLs via ECS task definitions (no hardcoded SSM paths)
# - Read-only on prod (pg_dump only). Destructive on dev/sandbox (drop schema + restore).
#
# Run from CloudShell in the PROD account (103869374886) after 7pm PT.

set -euo pipefail

# -------- Settings --------
PROD_ACCOUNT="103869374886"
DEV_ACCOUNT="008482603985"
SANDBOX_ACCOUNT="923561819954"
REGION="us-west-2"

PROD_CLUSTER="atlas-acuity-prod-cluster"
PROD_SERVICE="atlas-acuity-prod-acuity-svc"
DEV_CLUSTER="atlas-acuity-dev-cluster"
DEV_SERVICE="atlas-acuity-dev-acuity-svc"
SANDBOX_CLUSTER="atlas-acuity-sandbox-cluster"
SANDBOX_SERVICE="atlas-acuity-sandbox-acuity-svc"

EXCLUDE_DATA_TABLES=(
  "public.gmail_tokens"
  "public.prs_credentials"
)

WORK_DIR="/tmp/atlas-db-refresh-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$WORK_DIR"
DUMP_FILE="$WORK_DIR/prod.dump"

log() { echo "[$(date -u +%H:%M:%SZ)] $*"; }
fail() { log "ERROR: $*"; exit 1; }

# -------- Sanity: am I in prod account? --------
CURRENT_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
[[ "$CURRENT_ACCOUNT" == "$PROD_ACCOUNT" ]] || fail "Must run from PROD account ($PROD_ACCOUNT). Got: $CURRENT_ACCOUNT"
log "OK: in prod account $CURRENT_ACCOUNT"

# -------- Install postgresql-client if missing --------
if ! command -v pg_dump >/dev/null 2>&1; then
  log "Installing postgresql-client..."
  sudo yum install -y postgresql15 >/dev/null 2>&1 || sudo dnf install -y postgresql15 >/dev/null 2>&1 || fail "Could not install postgresql client"
fi
log "OK: pg_dump=$(pg_dump --version | head -1)"

# -------- Helper: discover DATABASE_URL from an ECS task def --------
# Usage: get_database_url <cluster> <service> [aws-profile-or-env-prefix]
discover_db_url() {
  local cluster="$1" service="$2" env_prefix="${3:-}"

  local task_def_arn
  task_def_arn=$(${env_prefix} aws ecs describe-services --cluster "$cluster" --services "$service" --region "$REGION" --query 'services[0].taskDefinition' --output text)
  [[ -n "$task_def_arn" && "$task_def_arn" != "None" ]] || fail "No task def for $cluster/$service"

  local ssm_arn
  ssm_arn=$(${env_prefix} aws ecs describe-task-definition --task-definition "$task_def_arn" --region "$REGION" \
    --query 'taskDefinition.containerDefinitions[0].secrets[?name==`DATABASE_URL`].valueFrom' --output text)
  [[ -n "$ssm_arn" && "$ssm_arn" != "None" ]] || fail "No DATABASE_URL secret on $cluster/$service task def"

  local ssm_name
  # valueFrom can be a full ARN or a bare name
  if [[ "$ssm_arn" == arn:* ]]; then
    ssm_name="${ssm_arn##*:parameter}"
  else
    ssm_name="$ssm_arn"
  fi

  ${env_prefix} aws ssm get-parameter --name "$ssm_name" --with-decryption --region "$REGION" --query 'Parameter.Value' --output text
}

# -------- Step 1: Discover & dump PROD --------
log "=== STEP 1: Discover prod DATABASE_URL ==="
PROD_URL=$(discover_db_url "$PROD_CLUSTER" "$PROD_SERVICE")
PROD_HOST=$(echo "$PROD_URL" | sed -E 's#.*@([^:/]+).*#\1#')
log "OK: prod DB host = $PROD_HOST"

# Strip ?sslmode= and use PGSSLMODE
PROD_URL_CLEAN=$(echo "$PROD_URL" | sed 's/[?&]sslmode=[^&]*//')

log "=== STEP 2: pg_dump from prod (read-only) ==="
EXCLUDE_ARGS=""
for t in "${EXCLUDE_DATA_TABLES[@]}"; do
  EXCLUDE_ARGS="$EXCLUDE_ARGS --exclude-table-data=$t"
done

PGSSLMODE=require pg_dump \
  --format=custom \
  --no-owner \
  --no-acl \
  --verbose \
  $EXCLUDE_ARGS \
  --file="$DUMP_FILE" \
  "$PROD_URL_CLEAN" 2>&1 | tail -30

DUMP_SIZE=$(du -h "$DUMP_FILE" | cut -f1)
log "OK: dump complete, size=$DUMP_SIZE, path=$DUMP_FILE"

# -------- Step 3: Verify prod still healthy (read-only operation should be safe) --------
PROD_HEALTH=$(curl -s -o /dev/null -w '%{http_code}' https://api.acuitysystems.net/api/health)
[[ "$PROD_HEALTH" == "200" ]] || fail "Prod health check failed AFTER dump: $PROD_HEALTH (this should never happen — pg_dump is read-only)"
log "OK: prod /api/health = 200 (intact)"

# -------- Step 4: Restore to DEV --------
log "=== STEP 3: AssumeRole into DEV ($DEV_ACCOUNT) ==="
DEV_CREDS=$(aws sts assume-role \
  --role-arn "arn:aws:iam::${DEV_ACCOUNT}:role/OrganizationAccountAccessRole" \
  --role-session-name atlas-db-refresh \
  --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
  --output text)
DEV_AKID=$(echo "$DEV_CREDS" | awk '{print $1}')
DEV_SAK=$(echo "$DEV_CREDS" | awk '{print $2}')
DEV_TOK=$(echo "$DEV_CREDS" | awk '{print $3}')
DEV_ENV="env AWS_ACCESS_KEY_ID=$DEV_AKID AWS_SECRET_ACCESS_KEY=$DEV_SAK AWS_SESSION_TOKEN=$DEV_TOK"

log "Discovering dev DATABASE_URL..."
DEV_URL=$(discover_db_url "$DEV_CLUSTER" "$DEV_SERVICE" "$DEV_ENV")
DEV_HOST=$(echo "$DEV_URL" | sed -E 's#.*@([^:/]+).*#\1#')
log "OK: dev DB host = $DEV_HOST"
DEV_URL_CLEAN=$(echo "$DEV_URL" | sed 's/[?&]sslmode=[^&]*//')

log "=== STEP 4: Drop dev public schema and restore ==="
PGSSLMODE=require psql "$DEV_URL_CLEAN" -v ON_ERROR_STOP=1 -c 'DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public; GRANT ALL ON SCHEMA public TO PUBLIC;'
PGSSLMODE=require pg_restore \
  --no-owner --no-acl --verbose \
  --schema=public \
  --dbname="$DEV_URL_CLEAN" \
  "$DUMP_FILE" 2>&1 | tail -20

# -------- Step 5: Restore to SANDBOX --------
log "=== STEP 5: AssumeRole into SANDBOX ($SANDBOX_ACCOUNT) ==="
SB_CREDS=$(aws sts assume-role \
  --role-arn "arn:aws:iam::${SANDBOX_ACCOUNT}:role/OrganizationAccountAccessRole" \
  --role-session-name atlas-db-refresh \
  --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
  --output text)
SB_AKID=$(echo "$SB_CREDS" | awk '{print $1}')
SB_SAK=$(echo "$SB_CREDS" | awk '{print $2}')
SB_TOK=$(echo "$SB_CREDS" | awk '{print $3}')
SB_ENV="env AWS_ACCESS_KEY_ID=$SB_AKID AWS_SECRET_ACCESS_KEY=$SB_SAK AWS_SESSION_TOKEN=$SB_TOK"

log "Discovering sandbox DATABASE_URL..."
SB_URL=$(discover_db_url "$SANDBOX_CLUSTER" "$SANDBOX_SERVICE" "$SB_ENV")
SB_HOST=$(echo "$SB_URL" | sed -E 's#.*@([^:/]+).*#\1#')
log "OK: sandbox DB host = $SB_HOST"
SB_URL_CLEAN=$(echo "$SB_URL" | sed 's/[?&]sslmode=[^&]*//')

log "=== STEP 6: Drop sandbox public schema and restore ==="
PGSSLMODE=require psql "$SB_URL_CLEAN" -v ON_ERROR_STOP=1 -c 'DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public; GRANT ALL ON SCHEMA public TO PUBLIC;'
PGSSLMODE=require pg_restore \
  --no-owner --no-acl --verbose \
  --schema=public \
  --dbname="$SB_URL_CLEAN" \
  "$DUMP_FILE" 2>&1 | tail -20

# -------- Step 6: Final verifies --------
log "=== STEP 7: Final health checks ==="
PROD_HEALTH=$(curl -s -o /dev/null -w '%{http_code}' https://api.acuitysystems.net/api/health)
DEV_HEALTH=$(curl -s -o /dev/null -w '%{http_code}' https://dev.acuitysystems.net/api/health)
SB_HEALTH=$(curl -s -o /dev/null -w '%{http_code}' https://demo.acuitysystems.net/api/health)
log "prod=$PROD_HEALTH dev=$DEV_HEALTH sandbox=$SB_HEALTH"

log "=== STEP 8: Verify dev/sandbox row counts ==="
echo "--- DEV ---"
PGSSLMODE=require psql "$DEV_URL_CLEAN" -t -c "SELECT 'agent_profiles=' || COUNT(*) FROM public.agent_profiles UNION ALL SELECT 'app_users=' || COUNT(*) FROM public.app_users UNION ALL SELECT 'system_users=' || COUNT(*) FROM public.system_users UNION ALL SELECT 'gmail_tokens=' || COUNT(*) FROM public.gmail_tokens UNION ALL SELECT 'letter_templates=' || COUNT(*) FROM public.letter_templates;" 2>&1 || true

echo "--- SANDBOX ---"
PGSSLMODE=require psql "$SB_URL_CLEAN" -t -c "SELECT 'agent_profiles=' || COUNT(*) FROM public.agent_profiles UNION ALL SELECT 'app_users=' || COUNT(*) FROM public.app_users UNION ALL SELECT 'system_users=' || COUNT(*) FROM public.system_users UNION ALL SELECT 'gmail_tokens=' || COUNT(*) FROM public.gmail_tokens UNION ALL SELECT 'letter_templates=' || COUNT(*) FROM public.letter_templates;" 2>&1 || true

log "=== DONE ==="
log "Expected: agent_profiles=10, app_users=7, system_users=15, gmail_tokens=0 (excluded), letter_templates=27"
log "Dump preserved at: $DUMP_FILE"
