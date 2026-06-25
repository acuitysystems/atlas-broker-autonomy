# Atlas Broker Autonomy Kit

CloudFormation 1-click installer for the Atlas Managed Care operations broker.

## What this deploys

A CloudFormation stack in AWS account `103869374886`, region `us-west-2`, that:

1. **Expands the existing `atlas-ops-broker` Lambda** with additional whitelisted commands (ECS task definition lookups, EFS recovery point listing, audit baseline read/write).
2. **Adds a hard-deny boundary policy** so the prod broker can never touch IAM writes, KMS, Secrets Manager, S3 bucket policies, or destroy ECS/RDS resources.
3. **Provisions a non-prod broker Lambda** (`atlas-ops-broker-nonprod`) for dev/demo environment refresh operations, with the same hard-deny boundary.
4. **Creates a private deploy bucket** to host broker code zips going forward.
5. **Wires three SSM parameters:**
   - `/atlas/broker/enabled` — panic-button kill switch (`true`/`false`)
   - `/atlas/broker/destructive-token` — required header for destructive commands (rotated quarterly)
   - `/atlas/broker/audit-baseline` — last-known-good infrastructure snapshot
6. **Schedules a daily 06:00 PT audit cron** that diffs current infrastructure against the baseline.

## What this kit does NOT include

- No secrets (broker code reads from SSM at runtime, never embeds values)
- No PHI or claimant data
- No production application code
- No database credentials

## Files

- `atlas-autonomy.yaml` — CloudFormation template (15 resources, 6 params, 6 outputs)
- `prod-broker.py` — Production broker Lambda source (read via Custom Resource at stack creation)
- `nonprod-broker.py` — Non-prod broker Lambda source (read via Custom Resource at stack creation)

## Install (1-click)

Click the link in the runbook (private — see `acuitysystems/operations-log` repo). The stack takes ~3-5 minutes to apply. After it finishes:

1. CloudFormation outputs the new deploy bucket name and the non-prod broker ARN
2. Run `update_self` on the prod broker via the existing Pipedream connector to swap to expanded code
3. Smoke-test both brokers with the `health` command

## Hard limits (preserved by design)

Both broker Lambdas have an explicit DENY on:

- `iam:*` (writes)
- `kms:*`
- `secretsmanager:*`
- `ssm:PutParameter`, `ssm:DeleteParameter`, `ssm:LabelParameterVersion`
- `s3:PutBucketPolicy`, `s3:DeleteBucket`
- `ecs:DeleteCluster`, `ecs:DeleteService`
- `rds:DeleteDBCluster`, `rds:DeleteDBInstance`

These cannot be bypassed without re-applying the CloudFormation stack with modified policies.

## Maintenance

To update broker code after stack is deployed:

1. Edit source files in `acuitysystems/atlas-broker-autonomy` (this repo)
2. Push to `main`
3. Invoke `update_self` on the target broker — it pulls the new code from raw.githubusercontent.com, zips it, and updates its own function code

The CloudFormation stack does NOT auto-update broker code on subsequent template changes. Broker self-update is the canonical refresh path.

## License

Internal Atlas Managed Care tooling. Public visibility is required for CloudFormation anonymous template fetch and Lambda Custom Resource code fetch. No proprietary application logic is exposed here.

## Contact

David Kim — davidk@atlasmanagedcare.com
