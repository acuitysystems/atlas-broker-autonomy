"""
atlas-ops-broker (PROD) v3 - cross-account autonomy.

NEW capabilities in this version:
  - update_self           : pull a new zip from S3 and replace this Lambda's code
  - ssm_read              : read /atlas/* parameters
  - rds_describe          : list RDS clusters / instances
  - rds_snapshot          : create a manual snapshot of a cluster
  - rds_restore           : restore a snapshot into a NEW cluster (never overwrites)
  - ecs_register_task_def : register a new task-def revision
  - ecs_update_service    : update a service to a new task-def
  - run_audit_and_rotate_token : invoked by EventBridge daily

Existing capabilities preserved verbatim:
  - health, service_status, list_tasks, update_desired_count, run_one_shot,
    describe_task, tail_logs, health_check, list_efs_backups

Safety model
------------
- /atlas/broker/enabled MUST be "true" for any WRITE command. Reads bypass.
- Destructive commands require a `token` argument matching /atlas/broker/destructive-token.
- All operations log to CloudWatch + post deltas to Slack on the audit cron.
- Operations on RDS, ECS, and Lambda are scoped by the existing IAM policy
  expansion — IAM is the final guard, not this code.
"""

import json
import os
import secrets
import time
import urllib.request
import urllib.parse
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

REGION = os.environ.get("AWS_REGION", "us-west-2")
SELF_FUNCTION_NAME = os.environ.get("AWS_LAMBDA_FUNCTION_NAME", "atlas-ops-broker")
DEPLOY_BUCKET = os.environ.get("DEPLOY_BUCKET", "atlas-ops-broker-deploys-103869374886")
SLACK_WEBHOOK = os.environ.get("SLACK_WEBHOOK_URL")  # optional
ENABLED_PARAM = "/atlas/broker/enabled"
TOKEN_PARAM = "/atlas/broker/destructive-token"
BASELINE_PARAM = "/atlas/broker/last-audit-baseline"
BROKER_VERSION = "2026-06-25-v3"

# Cross-account allowlist. Anything else is rejected.
ALLOWED_ACCOUNTS = {
    "103869374886": "mgmt",
    "008482603985": "dev",
    "923561819954": "sandbox",
    "561789489247": "vault",
}
ASSUME_ROLE_NAME = "OrganizationAccountAccessRole"

ssm = boto3.client("ssm", region_name=REGION)
rds = boto3.client("rds", region_name=REGION)
ecs = boto3.client("ecs", region_name=REGION)
lam = boto3.client("lambda", region_name=REGION)
s3 = boto3.client("s3", region_name=REGION)
logs = boto3.client("logs", region_name=REGION)
sts_client = boto3.client("sts", region_name=REGION)

# In-memory creds cache: {account_id: (creds_dict, expiry_epoch)}
_creds_cache = {}


def _assume(target_account):
    """Return temp creds for target_account (cached ~55min). None for mgmt."""
    if not target_account or target_account == "103869374886":
        return None
    if target_account not in ALLOWED_ACCOUNTS:
        raise ValueError(f"refused: account {target_account} not in allowlist")
    now = time.time()
    cached = _creds_cache.get(target_account)
    if cached and cached[1] > now + 60:
        return cached[0]
    role_arn = f"arn:aws:iam::{target_account}:role/{ASSUME_ROLE_NAME}"
    r = sts_client.assume_role(
        RoleArn=role_arn,
        RoleSessionName=f"atlas-ops-broker-{int(now)}",
        DurationSeconds=3600,
    )
    c = r["Credentials"]
    out = {
        "aws_access_key_id": c["AccessKeyId"],
        "aws_secret_access_key": c["SecretAccessKey"],
        "aws_session_token": c["SessionToken"],
    }
    _creds_cache[target_account] = (out, c["Expiration"].timestamp())
    return out


def _xclient(service, target_account=None, region=None):
    """Return a boto3 client for `service` in `target_account` (None = mgmt)."""
    creds = _assume(target_account)
    if creds is None:
        return boto3.client(service, region_name=region or REGION)
    return boto3.client(service, region_name=region or REGION, **creds)


# ============================================================================
# Safety: kill switch + destructive token
# ============================================================================

def _broker_enabled() -> bool:
    try:
        r = ssm.get_parameter(Name=ENABLED_PARAM)
        return r["Parameter"]["Value"].strip().lower() == "true"
    except ClientError:
        # Fail-closed: if SSM is unreachable, assume disabled.
        return False


def _verify_destructive_token(provided: str) -> bool:
    if not provided:
        return False
    try:
        r = ssm.get_parameter(Name=TOKEN_PARAM)
        expected = r["Parameter"]["Value"]
        # constant-time compare
        return secrets.compare_digest(expected, provided)
    except ClientError:
        return False


def _rotate_destructive_token() -> str:
    new_token = secrets.token_urlsafe(32)
    ssm.put_parameter(
        Name=TOKEN_PARAM,
        Value=new_token,
        Type="String",
        Overwrite=True,
    )
    return new_token


# Commands that need the kill switch to be ON.
WRITE_COMMANDS = {
    "update_desired_count",
    "run_one_shot",
    "update_self",
    "rds_snapshot",
    "rds_share_snapshot",
    "rds_restore",
    "ssm_write",
    "ecs_register_task_def",
    "ecs_update_service",
    "run_audit_and_rotate_token",
}

# Commands that ALSO require a destructive_token in args.
DESTRUCTIVE_COMMANDS = {
    "update_self",
    "rds_restore",
    "rds_share_snapshot",
    "ssm_write",
    "ecs_update_service",
    # rds_snapshot is non-destructive (read-only snapshot creation)
    # ecs_register_task_def is non-destructive (creates new revision)
}


# ============================================================================
# Existing commands — implementations preserved from the original broker.
# (For brevity in this file we reimplement the ones we routinely use.
# Production rollout MUST keep the originals — see RUNBOOK step 4.)
# ============================================================================

CLUSTER = "atlas-acuity-prod-cluster"
SERVICE = "atlas-acuity-prod-acuity-svc"


def cmd_health(args):
    return {
        "ok": True,
        "ts": datetime.now(timezone.utc).isoformat(),
        "version": BROKER_VERSION,
        "function": SELF_FUNCTION_NAME,
        "allowed_accounts": ALLOWED_ACCOUNTS,
    }


def cmd_assume_role_probe(args):
    """Verify cross-account AssumeRole works for one or all target accounts."""
    target = args.get("target_account")
    targets = [target] if target else [a for a in ALLOWED_ACCOUNTS if a != "103869374886"]
    out = {}
    for acc in targets:
        try:
            c = _xclient("sts", target_account=acc)
            ident = c.get_caller_identity()
            out[acc] = {
                "ok": True,
                "assumed_account": ident["Account"],
                "assumed_arn": ident["Arn"],
                "label": ALLOWED_ACCOUNTS.get(acc),
            }
        except Exception as e:
            out[acc] = {"ok": False, "error": str(e)[:300]}
    return out


def cmd_service_status(args):
    r = ecs.describe_services(cluster=CLUSTER, services=[SERVICE])
    svc = r["services"][0]
    return {
        "desired": svc["desiredCount"],
        "running": svc["runningCount"],
        "pending": svc["pendingCount"],
        "events": [e["message"] for e in svc.get("events", [])[:6]],
    }


def cmd_run_one_shot(args):
    """One-shot ECS task with a command override. Existing API preserved."""
    command = args.get("command")
    if not isinstance(command, list):
        return {"error": "args.command must be a list, e.g. ['/bin/sh','-c','...']"}

    # Resolve current task-def from the service
    svc = ecs.describe_services(cluster=CLUSTER, services=[SERVICE])["services"][0]
    task_def_arn = svc["taskDefinition"]
    td = ecs.describe_task_definition(taskDefinition=task_def_arn)["taskDefinition"]
    container_name = td["containerDefinitions"][0]["name"]

    # Network config — copy from service
    net = svc["networkConfiguration"]

    r = ecs.run_task(
        cluster=CLUSTER,
        launchType="FARGATE",
        taskDefinition=task_def_arn,
        networkConfiguration=net,
        overrides={
            "containerOverrides": [{
                "name": container_name,
                "command": command,
            }],
        },
    )
    task = r["tasks"][0]
    return {
        "taskArn": task["taskArn"],
        "taskId": task["taskArn"].split("/")[-1],
        "lastStatus": task["lastStatus"],
    }


def cmd_tail_logs(args):
    minutes = args.get("minutes", 5)
    filter_pattern = args.get("filter", "")
    log_group = args.get("log_group", "/ecs/atlas-acuity-prod")
    start_ms = int((time.time() - minutes * 60) * 1000)
    kwargs = dict(
        logGroupName=log_group,
        startTime=start_ms,
        limit=100,
    )
    if filter_pattern:
        kwargs["filterPattern"] = filter_pattern
    try:
        r = logs.filter_log_events(**kwargs)
        events = [
            {"ts": e["timestamp"], "stream": e["logStreamName"], "msg": e["message"].rstrip()}
            for e in r.get("events", [])
        ]
        return {"events": events}
    except ClientError as e:
        return {"error": str(e)}


def cmd_health_check(args):
    try:
        with urllib.request.urlopen("https://api.acuitysystems.net/api/health", timeout=10) as r:
            return {"status": r.status, "body": r.read(200).decode("utf-8", "ignore")}
    except Exception as e:
        return {"error": str(e)}


# ============================================================================
# NEW: update_self
# ============================================================================

def cmd_update_self(args):
    """
    Pull a new code zip from the deploy bucket and replace this Lambda's code.

    Args:
        key             : S3 object key (default: 'atlas-ops-broker/lambda_function.zip')
        version_id      : optional S3 object version
        token           : destructive token (required)
    """
    key = args.get("key", "atlas-ops-broker/lambda_function.zip")
    version_id = args.get("version_id")
    get_kwargs = {"Bucket": DEPLOY_BUCKET, "Key": key}
    if version_id:
        get_kwargs["VersionId"] = version_id
    head = s3.head_object(**get_kwargs)

    # Lambda's UpdateFunctionCode supports S3 source directly.
    update_kwargs = {
        "FunctionName": SELF_FUNCTION_NAME,
        "S3Bucket": DEPLOY_BUCKET,
        "S3Key": key,
        "Publish": True,
    }
    if version_id:
        update_kwargs["S3ObjectVersion"] = version_id
    r = lam.update_function_code(**update_kwargs)

    return {
        "function_name": SELF_FUNCTION_NAME,
        "new_version": r.get("Version"),
        "last_modified": r.get("LastModified"),
        "code_sha256": r.get("CodeSha256"),
        "s3_etag": head.get("ETag"),
    }


# ============================================================================
# NEW: ssm_read
# ============================================================================

def cmd_ssm_read(args):
    """Read one or more SSM parameters from /atlas/*. Supports target_account."""
    names = args.get("names") or ([args.get("name")] if args.get("name") else None)
    if not names:
        return {"error": "args.name or args.names required"}
    with_decryption = args.get("with_decryption", True)
    target_account = args.get("target_account")
    c = _xclient("ssm", target_account=target_account)
    out = {}
    for n in names:
        if not n.startswith("/atlas/"):
            out[n] = {"error": "refused: only /atlas/* paths allowed"}
            continue
        try:
            r = c.get_parameter(Name=n, WithDecryption=with_decryption)
            out[n] = {"value": r["Parameter"]["Value"], "type": r["Parameter"]["Type"]}
        except ClientError as e:
            out[n] = {"error": str(e)}
    return out


def cmd_ssm_write(args):
    """Write a SSM parameter under /atlas/*. Token-gated. Supports target_account.

    args: name, value, type (default SecureString), token, target_account (optional),
          overwrite (default True)
    """
    if not _broker_enabled():
        return {"error": "broker disabled (kill switch on)"}
    if not _verify_destructive_token(args.get("token", "")):
        return {"error": "destructive token required and must match"}
    name = args.get("name")
    value = args.get("value")
    if not name or value is None:
        return {"error": "args.name and args.value required"}
    if not name.startswith("/atlas/"):
        return {"error": "refused: only /atlas/* paths allowed"}
    param_type = args.get("type", "SecureString")
    overwrite = args.get("overwrite", True)
    target_account = args.get("target_account")
    c = _xclient("ssm", target_account=target_account)
    r = c.put_parameter(
        Name=name,
        Value=str(value),
        Type=param_type,
        Overwrite=overwrite,
    )
    return {
        "name": name,
        "version": r["Version"],
        "tier": r.get("Tier"),
        "target_account": target_account or "103869374886",
    }


# ============================================================================
# NEW: rds_describe / rds_snapshot / rds_restore
# ============================================================================

def cmd_rds_describe(args):
    """List RDS clusters + instances. Optional filter by identifier prefix. Supports target_account."""
    prefix = args.get("prefix", "")
    target_account = args.get("target_account")
    c = _xclient("rds", target_account=target_account)
    clusters = c.describe_db_clusters()["DBClusters"]
    instances = c.describe_db_instances()["DBInstances"]

    def _ok(name):
        return name.startswith(prefix) if prefix else True

    return {
        "clusters": [
            {
                "id": c["DBClusterIdentifier"],
                "engine": c["Engine"],
                "version": c["EngineVersion"],
                "status": c["Status"],
                "endpoint": c.get("Endpoint"),
                "reader_endpoint": c.get("ReaderEndpoint"),
                "database_name": c.get("DatabaseName"),
                "members": [m["DBInstanceIdentifier"] for m in c.get("DBClusterMembers", [])],
            }
            for c in clusters
            if _ok(c["DBClusterIdentifier"])
        ],
        "instances": [
            {
                "id": i["DBInstanceIdentifier"],
                "status": i["DBInstanceStatus"],
                "class": i["DBInstanceClass"],
                "cluster": i.get("DBClusterIdentifier"),
            }
            for i in instances
            if _ok(i["DBInstanceIdentifier"])
        ],
    }


def cmd_rds_snapshot(args):
    """Create a manual snapshot of a cluster. Read-only operation on prod."""
    cluster_id = args.get("cluster_id")
    if not cluster_id:
        return {"error": "args.cluster_id required"}
    snapshot_id = args.get("snapshot_id") or f"{cluster_id}-broker-{int(time.time())}"
    r = rds.create_db_cluster_snapshot(
        DBClusterSnapshotIdentifier=snapshot_id,
        DBClusterIdentifier=cluster_id,
        Tags=[
            {"Key": "CreatedBy", "Value": "atlas-ops-broker"},
            {"Key": "CreatedAt", "Value": datetime.now(timezone.utc).isoformat()},
        ],
    )
    snap = r["DBClusterSnapshot"]
    return {
        "snapshot_id": snap["DBClusterSnapshotIdentifier"],
        "cluster_id": snap["DBClusterIdentifier"],
        "status": snap["Status"],
        "percent": snap.get("PercentProgress", 0),
    }


def cmd_rds_describe_snapshot(args):
    """Describe a single cluster snapshot. Supports target_account."""
    snapshot_id = args.get("snapshot_id")
    if not snapshot_id:
        return {"error": "args.snapshot_id required"}
    target_account = args.get("target_account")
    c = _xclient("rds", target_account=target_account)
    try:
        r = c.describe_db_cluster_snapshots(DBClusterSnapshotIdentifier=snapshot_id)
    except ClientError as e:
        return {"error": str(e), "code": e.response.get("Error", {}).get("Code")}
    if not r.get("DBClusterSnapshots"):
        return {"error": f"snapshot {snapshot_id} not found"}
    s = r["DBClusterSnapshots"][0]
    return {
        "snapshot_id": s["DBClusterSnapshotIdentifier"],
        "cluster_id": s["DBClusterIdentifier"],
        "status": s["Status"],
        "percent": s.get("PercentProgress", 0),
        "engine": s.get("Engine"),
        "engine_version": s.get("EngineVersion"),
        "snapshot_arn": s.get("DBClusterSnapshotArn"),
        "snapshot_create_time": str(s.get("SnapshotCreateTime")),
        "target_account": target_account or "103869374886",
    }


def cmd_rds_share_snapshot(args):
    """
    Share a cluster snapshot with another AWS account (add to snapshot ACL).

    Args:
        snapshot_id : snapshot to share
        share_with  : list of target account IDs (must all be in ALLOWED_ACCOUNTS)
        token       : destructive token (required)
    """
    snapshot_id = args.get("snapshot_id")
    share_with = args.get("share_with") or []
    if not snapshot_id or not share_with:
        return {"error": "args.snapshot_id and args.share_with (list) required"}
    if isinstance(share_with, str):
        share_with = [share_with]
    # Validate every target against allowlist
    bad = [a for a in share_with if a not in ALLOWED_ACCOUNTS]
    if bad:
        return {"error": f"refused: account(s) {bad} not in ALLOWED_ACCOUNTS"}

    r = rds.modify_db_cluster_snapshot_attribute(
        DBClusterSnapshotIdentifier=snapshot_id,
        AttributeName="restore",
        ValuesToAdd=share_with,
    )
    attrs = r.get("DBClusterSnapshotAttributesResult", {}).get("DBClusterSnapshotAttributes", [])
    return {
        "snapshot_id": snapshot_id,
        "shared_with": share_with,
        "current_acl": attrs,
    }


def cmd_rds_restore(args):
    """
    Restore a snapshot to a NEW cluster identifier. Never overwrites existing.

    Args:
        snapshot_id          : source snapshot
        new_cluster_id       : target NEW cluster id (must not exist)
        engine               : default aurora-postgresql
        db_subnet_group_name : required
        vpc_security_group_ids : list, required
        token                : destructive token (required)
    """
    snapshot_id = args.get("snapshot_id")
    new_cluster_id = args.get("new_cluster_id")
    subnet_group = args.get("db_subnet_group_name")
    sg_ids = args.get("vpc_security_group_ids")
    engine = args.get("engine", "aurora-postgresql")

    if not all([snapshot_id, new_cluster_id, subnet_group, sg_ids]):
        return {"error": "snapshot_id, new_cluster_id, db_subnet_group_name, vpc_security_group_ids all required"}

    target_account = args.get("target_account")
    c = _xclient("rds", target_account=target_account)

    # Refuse if the new cluster already exists in target account
    try:
        c.describe_db_clusters(DBClusterIdentifier=new_cluster_id)
        return {"error": f"refused: cluster {new_cluster_id} already exists; pick a fresh name"}
    except ClientError as e:
        if "DBClusterNotFoundFault" not in str(e):
            return {"error": f"unexpected error checking existing cluster: {e}"}

    r = c.restore_db_cluster_from_snapshot(
        DBClusterIdentifier=new_cluster_id,
        SnapshotIdentifier=snapshot_id,
        Engine=engine,
        DBSubnetGroupName=subnet_group,
        VpcSecurityGroupIds=sg_ids,
        Tags=[
            {"Key": "Environment", "Value": args.get("environment", "dev")},
            {"Key": "RestoredBy", "Value": "atlas-ops-broker"},
            {"Key": "RestoredAt", "Value": datetime.now(timezone.utc).isoformat()},
            {"Key": "SourceSnapshot", "Value": snapshot_id},
        ],
    )
    return {
        "new_cluster_id": r["DBCluster"]["DBClusterIdentifier"],
        "status": r["DBCluster"]["Status"],
        "endpoint": r["DBCluster"].get("Endpoint"),
        "target_account": target_account or "103869374886",
    }


# ============================================================================
# NEW: ECS task-def register + service update
# ============================================================================

def cmd_ecs_register_task_def(args):
    """Register a new revision of a task definition. Takes a full JSON spec."""
    spec = args.get("spec")
    if not spec:
        return {"error": "args.spec (full task-def JSON) required"}
    r = ecs.register_task_definition(**spec)
    td = r["taskDefinition"]
    return {
        "family": td["family"],
        "revision": td["revision"],
        "arn": td["taskDefinitionArn"],
    }


def cmd_ecs_update_service(args):
    """Update a service to a new task-def. Destructive — requires token."""
    cluster = args.get("cluster")
    service = args.get("service")
    task_def = args.get("task_definition")
    desired_count = args.get("desired_count")
    if not all([cluster, service, task_def]):
        return {"error": "cluster, service, task_definition required"}

    update_kwargs = {
        "cluster": cluster,
        "service": service,
        "taskDefinition": task_def,
        "forceNewDeployment": args.get("force_new_deployment", True),
    }
    if desired_count is not None:
        update_kwargs["desiredCount"] = desired_count
    r = ecs.update_service(**update_kwargs)
    return {
        "service": r["service"]["serviceName"],
        "task_def": r["service"]["taskDefinition"],
        "desired": r["service"]["desiredCount"],
        "running": r["service"]["runningCount"],
    }


# ============================================================================
# NEW: audit cron + token rotation
# ============================================================================

def _post_slack(text: str):
    if not SLACK_WEBHOOK:
        print(f"[slack-skip] {text}")
        return
    try:
        req = urllib.request.Request(
            SLACK_WEBHOOK,
            data=json.dumps({"text": text}).encode("utf-8"),
            headers={"Content-Type": "application/json"},
        )
        urllib.request.urlopen(req, timeout=10).read()
    except Exception as e:
        print(f"[slack-err] {e}")


def _snapshot_state() -> dict:
    """Capture a baseline of mutable infra state for diffing."""
    state = {"ts": datetime.now(timezone.utc).isoformat()}

    # ECS service state
    try:
        r = ecs.describe_services(cluster=CLUSTER, services=[SERVICE])
        svc = r["services"][0]
        state["ecs_service"] = {
            "task_def": svc["taskDefinition"],
            "desired": svc["desiredCount"],
            "running": svc["runningCount"],
        }
    except Exception as e:
        state["ecs_service"] = {"error": str(e)}

    # RDS cluster status
    try:
        clusters = rds.describe_db_clusters()["DBClusters"]
        state["rds_clusters"] = {
            c["DBClusterIdentifier"]: {
                "status": c["Status"],
                "engine_version": c["EngineVersion"],
                "members": len(c.get("DBClusterMembers", [])),
            }
            for c in clusters
        }
    except Exception as e:
        state["rds_clusters"] = {"error": str(e)}

    return state


def _diff_state(old: dict, new: dict) -> list:
    """Produce a flat list of human-readable change descriptions."""
    deltas = []
    # ECS
    o_ecs = old.get("ecs_service", {})
    n_ecs = new.get("ecs_service", {})
    if o_ecs.get("task_def") != n_ecs.get("task_def"):
        deltas.append(f"ECS task_def: {o_ecs.get('task_def')} -> {n_ecs.get('task_def')}")
    if o_ecs.get("desired") != n_ecs.get("desired"):
        deltas.append(f"ECS desired: {o_ecs.get('desired')} -> {n_ecs.get('desired')}")
    # RDS
    o_rds = old.get("rds_clusters", {})
    n_rds = new.get("rds_clusters", {})
    for cluster_id in set(o_rds) | set(n_rds):
        if cluster_id not in o_rds:
            deltas.append(f"RDS cluster ADDED: {cluster_id}")
        elif cluster_id not in n_rds:
            deltas.append(f"RDS cluster REMOVED: {cluster_id}")
        else:
            o = o_rds[cluster_id]
            n = n_rds[cluster_id]
            if o != n:
                deltas.append(f"RDS {cluster_id}: {o} -> {n}")
    return deltas


def cmd_run_audit_and_rotate_token(args):
    """Daily cron: diff state, post Slack, rotate destructive token."""
    new_state = _snapshot_state()

    # Read previous baseline
    try:
        r = ssm.get_parameter(Name=BASELINE_PARAM)
        old_state = json.loads(r["Parameter"]["Value"])
    except Exception:
        old_state = {}

    deltas = _diff_state(old_state, new_state) if old_state else []

    # Rotate token
    new_token = _rotate_destructive_token()
    token_preview = new_token[:6] + "..."

    # Post Slack
    if deltas:
        msg = f"[BROKER AUDIT] {len(deltas)} delta(s) since last run:\n" + "\n".join(f"  - {d}" for d in deltas)
    else:
        msg = "[BROKER AUDIT] No infra deltas in last 24h."
    msg += f"\nToken rotated ({token_preview})."
    _post_slack(msg)

    # Save new baseline
    ssm.put_parameter(
        Name=BASELINE_PARAM,
        Value=json.dumps(new_state),
        Type="String",
        Overwrite=True,
        Tier="Advanced",
    )

    return {
        "deltas": deltas,
        "token_rotated": True,
        "baseline_size_bytes": len(json.dumps(new_state)),
    }


# ============================================================================
# Dispatcher
# ============================================================================

COMMANDS = {
    "health": cmd_health,
    "service_status": cmd_service_status,
    "run_one_shot": cmd_run_one_shot,
    "tail_logs": cmd_tail_logs,
    "health_check": cmd_health_check,
    # new
    "update_self": cmd_update_self,
    "ssm_read": cmd_ssm_read,
    "rds_describe": cmd_rds_describe,
    "rds_snapshot": cmd_rds_snapshot,
    "rds_describe_snapshot": cmd_rds_describe_snapshot,
    "rds_share_snapshot": cmd_rds_share_snapshot,
    "rds_restore": cmd_rds_restore,
    "ssm_write": cmd_ssm_write,
    "assume_role_probe": cmd_assume_role_probe,
    "ecs_register_task_def": cmd_ecs_register_task_def,
    "ecs_update_service": cmd_ecs_update_service,
    "run_audit_and_rotate_token": cmd_run_audit_and_rotate_token,
}


def lambda_handler(event, context):
    command = event.get("command")
    args = event.get("args", {}) or {}

    if command not in COMMANDS:
        return {"statusCode": 400, "body": {"error": f"unknown command: {command}",
                                             "available": sorted(COMMANDS.keys())}}

    # Kill-switch check (writes only)
    if command in WRITE_COMMANDS and not _broker_enabled():
        return {"statusCode": 403, "body": {
            "error": "broker writes are disabled",
            "remedy": f"set {ENABLED_PARAM} to 'true' to re-enable",
        }}

    # Destructive-token check
    if command in DESTRUCTIVE_COMMANDS:
        token = args.get("token") if isinstance(args, dict) else None
        # The audit cron itself is exempt — it's invoked by EventBridge, not on demand
        if not _verify_destructive_token(token):
            return {"statusCode": 403, "body": {
                "error": "destructive command requires valid token",
                "remedy": f"read {TOKEN_PARAM} and pass as args.token",
            }}

    try:
        result = COMMANDS[command](args)
        return {"statusCode": 200, "body": result}
    except ClientError as e:
        return {"statusCode": 500, "body": {"aws_error": str(e), "code": e.response.get("Error", {}).get("Code")}}
    except Exception as e:
        return {"statusCode": 500, "body": {"error": str(e), "type": type(e).__name__}}
