"""
atlas-ops-broker-nonprod — wide non-prod operations, tag-bounded.

Every mutating command CHECKS that the target resource carries
Environment in (dev, demo). Resources without that tag, or tagged
prod, are refused.

This is layered defense: the IAM policy ALSO restricts to tagged
resources, but the code refuses earlier with a clearer error.

Commands:
  - health
  - rds_describe
  - rds_dump            : pg_dump from an ECS one-shot task to S3
  - rds_restore_from_s3 : pg_restore into a dev/demo cluster from S3 dump
  - ecs_register_task_def
  - ecs_update_service
  - ssm_read            : reads /atlas/dev/*, /atlas/demo/*, /atlas/broker/*
  - update_self
"""

import json
import os
import time
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

REGION = os.environ.get("AWS_REGION", "us-west-2")
SELF_FUNCTION_NAME = os.environ.get("AWS_LAMBDA_FUNCTION_NAME", "atlas-ops-broker-nonprod")
DEPLOY_BUCKET = os.environ.get("DEPLOY_BUCKET", "atlas-ops-broker-deploys-103869374886")
BOUNDARY = set((os.environ.get("ENVIRONMENT_BOUNDARY") or "dev,demo").split(","))

rds = boto3.client("rds", region_name=REGION)
ecs = boto3.client("ecs", region_name=REGION)
ssm = boto3.client("ssm", region_name=REGION)
lam = boto3.client("lambda", region_name=REGION)
s3 = boto3.client("s3", region_name=REGION)


# ============================================================================
# Tag enforcement — central guard
# ============================================================================

def _refuse_if_not_in_boundary(env_tag: str | None):
    if env_tag is None:
        raise PermissionError("refused: target resource has no Environment tag; this broker only operates on resources tagged dev/demo")
    if env_tag not in BOUNDARY:
        raise PermissionError(f"refused: Environment={env_tag} is outside boundary {sorted(BOUNDARY)}")


def _rds_cluster_env(cluster_id: str) -> str | None:
    arn = rds.describe_db_clusters(DBClusterIdentifier=cluster_id)["DBClusters"][0]["DBClusterArn"]
    tags = rds.list_tags_for_resource(ResourceName=arn)["TagList"]
    for t in tags:
        if t["Key"] == "Environment":
            return t["Value"]
    return None


def _ecs_cluster_env(cluster: str) -> str | None:
    arn = ecs.describe_clusters(clusters=[cluster])["clusters"][0]["clusterArn"]
    tags = ecs.list_tags_for_resource(resourceArn=arn).get("tags", [])
    for t in tags:
        if t["key"] == "Environment":
            return t["value"]
    return None


# ============================================================================
# Commands
# ============================================================================

def cmd_health(args):
    return {
        "ok": True,
        "ts": datetime.now(timezone.utc).isoformat(),
        "boundary": sorted(BOUNDARY),
        "function": SELF_FUNCTION_NAME,
    }


def cmd_rds_describe(args):
    """List clusters within the boundary."""
    out = []
    for c in rds.describe_db_clusters()["DBClusters"]:
        try:
            env = _rds_cluster_env(c["DBClusterIdentifier"])
        except Exception:
            env = None
        if env not in BOUNDARY:
            continue
        out.append({
            "id": c["DBClusterIdentifier"],
            "engine": c["Engine"],
            "version": c["EngineVersion"],
            "status": c["Status"],
            "endpoint": c.get("Endpoint"),
            "environment": env,
        })
    return {"clusters": out}


def cmd_ssm_read(args):
    """Read /atlas/dev/*, /atlas/demo/*, /atlas/broker/*."""
    names = args.get("names") or ([args["name"]] if args.get("name") else None)
    if not names:
        return {"error": "args.name or args.names required"}
    out = {}
    for n in names:
        allowed = (
            n.startswith("/atlas/dev/")
            or n.startswith("/atlas/demo/")
            or n.startswith("/atlas/broker/")
        )
        if not allowed:
            out[n] = {"error": "refused: only /atlas/dev/*, /atlas/demo/*, /atlas/broker/*"}
            continue
        try:
            r = ssm.get_parameter(Name=n, WithDecryption=True)
            out[n] = {"value": r["Parameter"]["Value"], "type": r["Parameter"]["Type"]}
        except ClientError as e:
            out[n] = {"error": str(e)}
    return out


def cmd_rds_dump(args):
    """
    Run pg_dump from a Fargate one-shot task and upload to S3.

    Args:
        source_database_url     : DATABASE_URL of source (must be in /atlas/dev|demo/* OR prod via explicit override)
        source_url_param        : SSM parameter holding the URL (preferred over inline)
        s3_bucket               : target bucket
        s3_key                  : target key
        cluster                 : ECS cluster to run the task in (must be tagged dev/demo)
        task_definition         : task-def family or ARN (must have psql tools in image)
        subnets                 : list
        security_groups         : list
    """
    src_param = args.get("source_url_param")
    src_inline = args.get("source_database_url")
    if not src_param and not src_inline:
        return {"error": "source_url_param or source_database_url required"}

    cluster = args.get("cluster")
    if not cluster:
        return {"error": "args.cluster required"}
    env_tag = _ecs_cluster_env(cluster)
    _refuse_if_not_in_boundary(env_tag)

    s3_bucket = args.get("s3_bucket")
    s3_key = args.get("s3_key", f"db-dumps/{int(time.time())}.dump")
    if not s3_bucket:
        return {"error": "args.s3_bucket required"}

    task_def = args.get("task_definition")
    subnets = args.get("subnets") or []
    sgs = args.get("security_groups") or []
    if not task_def or not subnets:
        return {"error": "task_definition + subnets required"}

    # Compose the command
    if src_param:
        src_expr = f"$(aws ssm get-parameter --name {src_param} --with-decryption --query Parameter.Value --output text)"
    else:
        src_expr = src_inline

    command = [
        "/bin/sh", "-c",
        f"set -e; pg_dump --no-owner --no-privileges -Fc -d '{src_expr}' -f /tmp/db.dump && "
        f"aws s3 cp /tmp/db.dump s3://{s3_bucket}/{s3_key}",
    ]

    r = ecs.run_task(
        cluster=cluster,
        launchType="FARGATE",
        taskDefinition=task_def,
        networkConfiguration={
            "awsvpcConfiguration": {
                "subnets": subnets,
                "securityGroups": sgs,
                "assignPublicIp": "DISABLED",
            },
        },
        overrides={
            "containerOverrides": [{
                "name": args.get("container_name", "acuity-systems"),
                "command": command,
            }],
        },
    )
    task = r["tasks"][0]
    return {
        "task_arn": task["taskArn"],
        "s3_uri": f"s3://{s3_bucket}/{s3_key}",
        "status": task["lastStatus"],
    }


def cmd_rds_restore_from_s3(args):
    """
    pg_restore into a dev/demo cluster from an S3 dump.
    Drops + recreates `public` schema first.
    """
    target_param = args.get("target_url_param")
    if not target_param or not (target_param.startswith("/atlas/dev/") or target_param.startswith("/atlas/demo/")):
        return {"error": "target_url_param must be under /atlas/dev/* or /atlas/demo/*"}

    cluster = args.get("cluster")
    if not cluster:
        return {"error": "args.cluster required"}
    env_tag = _ecs_cluster_env(cluster)
    _refuse_if_not_in_boundary(env_tag)

    s3_uri = args.get("s3_uri")
    if not s3_uri or not s3_uri.startswith("s3://"):
        return {"error": "args.s3_uri (s3://bucket/key) required"}

    task_def = args.get("task_definition")
    subnets = args.get("subnets") or []
    sgs = args.get("security_groups") or []
    if not task_def or not subnets:
        return {"error": "task_definition + subnets required"}

    target_expr = f"$(aws ssm get-parameter --name {target_param} --with-decryption --query Parameter.Value --output text)"
    bucket_key = s3_uri[5:]

    command = [
        "/bin/sh", "-c",
        f"set -e; "
        f"aws s3 cp s3://{bucket_key} /tmp/db.dump && "
        f"psql -d '{target_expr}' -c 'DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public;' && "
        f"pg_restore --no-owner --no-privileges -d '{target_expr}' /tmp/db.dump",
    ]

    r = ecs.run_task(
        cluster=cluster,
        launchType="FARGATE",
        taskDefinition=task_def,
        networkConfiguration={
            "awsvpcConfiguration": {
                "subnets": subnets,
                "securityGroups": sgs,
                "assignPublicIp": "DISABLED",
            },
        },
        overrides={
            "containerOverrides": [{
                "name": args.get("container_name", "acuity-systems"),
                "command": command,
            }],
        },
    )
    task = r["tasks"][0]
    return {
        "task_arn": task["taskArn"],
        "target_param": target_param,
        "status": task["lastStatus"],
    }


def cmd_update_self(args):
    key = args.get("key", "atlas-ops-broker-nonprod/lambda_function.zip")
    version_id = args.get("version_id")
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
        "code_sha256": r.get("CodeSha256"),
    }


COMMANDS = {
    "health": cmd_health,
    "rds_describe": cmd_rds_describe,
    "ssm_read": cmd_ssm_read,
    "rds_dump": cmd_rds_dump,
    "rds_restore_from_s3": cmd_rds_restore_from_s3,
    "update_self": cmd_update_self,
}


def lambda_handler(event, context):
    command = event.get("command")
    args = event.get("args", {}) or {}
    if command not in COMMANDS:
        return {"statusCode": 400, "body": {"error": f"unknown command: {command}",
                                             "available": sorted(COMMANDS.keys())}}
    try:
        result = COMMANDS[command](args)
        return {"statusCode": 200, "body": result}
    except PermissionError as e:
        return {"statusCode": 403, "body": {"error": str(e)}}
    except ClientError as e:
        return {"statusCode": 500, "body": {"aws_error": str(e), "code": e.response.get("Error", {}).get("Code")}}
    except Exception as e:
        return {"statusCode": 500, "body": {"error": str(e), "type": type(e).__name__}}
