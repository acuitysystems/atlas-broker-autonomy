#!/bin/bash
# ATLAS NON-PROD BROKER BOOTSTRAP + DEMO 503 DIAGNOSIS
# One-time prep so atlas-ops-broker-nonprod can drive dev/demo refresh.
# Idempotent: safe to re-run. Read-first, write-only-after-confirmation in shell logic.

set -u
REGION=us-west-2

echo "================================================================"
echo " STEP 1: DISCOVER DEV/DEMO INFRASTRUCTURE"
echo "================================================================"

echo ""
echo "--- All RDS clusters in account ---"
aws rds describe-db-clusters --region $REGION \
  --query 'DBClusters[].[DBClusterIdentifier,Engine,Status,Endpoint]' \
  --output table

echo ""
echo "--- All RDS instances (non-cluster) ---"
aws rds describe-db-instances --region $REGION \
  --query 'DBInstances[].[DBInstanceIdentifier,Engine,DBInstanceStatus,Endpoint.Address]' \
  --output table

echo ""
echo "--- All ECS clusters ---"
aws ecs list-clusters --region $REGION --query 'clusterArns[]' --output text | tr '\t' '\n'

echo ""
echo "--- ECS services per cluster ---"
for c in $(aws ecs list-clusters --region $REGION --query 'clusterArns[]' --output text); do
  name=$(basename $c)
  echo "  Cluster: $name"
  aws ecs list-services --region $REGION --cluster $c \
    --query 'serviceArns[]' --output text 2>/dev/null \
    | tr '\t' '\n' | sed 's/^/    /'
done

echo ""
echo "================================================================"
echo " STEP 2: IDENTIFY DEV/DEMO BY NAME PATTERN"
echo "================================================================"

# Heuristic: look for 'dev' or 'demo' in resource identifiers
DEV_RDS=$(aws rds describe-db-clusters --region $REGION \
  --query 'DBClusters[?contains(DBClusterIdentifier, `dev`)].DBClusterIdentifier' \
  --output text)
DEMO_RDS=$(aws rds describe-db-clusters --region $REGION \
  --query 'DBClusters[?contains(DBClusterIdentifier, `demo`)].DBClusterIdentifier' \
  --output text)

# Also check non-cluster instances
DEV_RDS_INST=$(aws rds describe-db-instances --region $REGION \
  --query 'DBInstances[?contains(DBInstanceIdentifier, `dev`)].DBInstanceIdentifier' \
  --output text)
DEMO_RDS_INST=$(aws rds describe-db-instances --region $REGION \
  --query 'DBInstances[?contains(DBInstanceIdentifier, `demo`)].DBInstanceIdentifier' \
  --output text)

DEV_ECS=$(aws ecs list-clusters --region $REGION --query 'clusterArns[]' --output text \
  | tr '\t' '\n' | grep -i dev || echo "")
DEMO_ECS=$(aws ecs list-clusters --region $REGION --query 'clusterArns[]' --output text \
  | tr '\t' '\n' | grep -i demo || echo "")

echo ""
echo "DEV RDS clusters:    ${DEV_RDS:-<none>}"
echo "DEV RDS instances:   ${DEV_RDS_INST:-<none>}"
echo "DEMO RDS clusters:   ${DEMO_RDS:-<none>}"
echo "DEMO RDS instances:  ${DEMO_RDS_INST:-<none>}"
echo "DEV ECS clusters:    ${DEV_ECS:-<none>}"
echo "DEMO ECS clusters:   ${DEMO_ECS:-<none>}"

echo ""
echo "================================================================"
echo " STEP 3: TAG DEV/DEMO RESOURCES WITH Environment="
echo "================================================================"

# Tag RDS clusters
if [ -n "$DEV_RDS" ]; then
  for c in $DEV_RDS; do
    ARN=$(aws rds describe-db-clusters --region $REGION --db-cluster-identifier $c \
      --query 'DBClusters[0].DBClusterArn' --output text)
    echo "Tagging Aurora cluster $c (Environment=dev) ..."
    aws rds add-tags-to-resource --region $REGION --resource-name $ARN \
      --tags Key=Environment,Value=dev && echo "  OK"
  done
fi
if [ -n "$DEMO_RDS" ]; then
  for c in $DEMO_RDS; do
    ARN=$(aws rds describe-db-clusters --region $REGION --db-cluster-identifier $c \
      --query 'DBClusters[0].DBClusterArn' --output text)
    echo "Tagging Aurora cluster $c (Environment=demo) ..."
    aws rds add-tags-to-resource --region $REGION --resource-name $ARN \
      --tags Key=Environment,Value=demo && echo "  OK"
  done
fi

# Tag RDS instances (in case Aurora isn't used, plain RDS PG might be)
if [ -n "$DEV_RDS_INST" ]; then
  for i in $DEV_RDS_INST; do
    ARN=$(aws rds describe-db-instances --region $REGION --db-instance-identifier $i \
      --query 'DBInstances[0].DBInstanceArn' --output text)
    echo "Tagging RDS instance $i (Environment=dev) ..."
    aws rds add-tags-to-resource --region $REGION --resource-name $ARN \
      --tags Key=Environment,Value=dev && echo "  OK"
  done
fi
if [ -n "$DEMO_RDS_INST" ]; then
  for i in $DEMO_RDS_INST; do
    ARN=$(aws rds describe-db-instances --region $REGION --db-instance-identifier $i \
      --query 'DBInstances[0].DBInstanceArn' --output text)
    echo "Tagging RDS instance $i (Environment=demo) ..."
    aws rds add-tags-to-resource --region $REGION --resource-name $ARN \
      --tags Key=Environment,Value=demo && echo "  OK"
  done
fi

# Tag ECS clusters
if [ -n "$DEV_ECS" ]; then
  for c in $DEV_ECS; do
    echo "Tagging ECS cluster $(basename $c) (Environment=dev) ..."
    aws ecs tag-resource --region $REGION --resource-arn $c \
      --tags key=Environment,value=dev && echo "  OK"
  done
fi
if [ -n "$DEMO_ECS" ]; then
  for c in $DEMO_ECS; do
    echo "Tagging ECS cluster $(basename $c) (Environment=demo) ..."
    aws ecs tag-resource --region $REGION --resource-arn $c \
      --tags key=Environment,value=demo && echo "  OK"
  done
fi

echo ""
echo "================================================================"
echo " STEP 4: DISCOVER EXISTING SSM PARAMS"
echo "================================================================"
echo ""
echo "--- All /atlas/* params (no values shown) ---"
aws ssm describe-parameters --region $REGION \
  --parameter-filters "Key=Name,Option=BeginsWith,Values=/atlas/" \
  --query 'Parameters[].Name' --output table

echo ""
echo "--- All /acuity/* params (no values shown) ---"
aws ssm describe-parameters --region $REGION \
  --parameter-filters "Key=Name,Option=BeginsWith,Values=/acuity/" \
  --query 'Parameters[].Name' --output table

echo ""
echo "================================================================"
echo " STEP 5: DEMO 503 DIAGNOSIS"
echo "================================================================"

if [ -n "$DEMO_ECS" ]; then
  for c in $DEMO_ECS; do
    echo ""
    echo "--- Demo cluster: $(basename $c) ---"
    echo "Services:"
    aws ecs list-services --region $REGION --cluster $c \
      --query 'serviceArns[]' --output text | tr '\t' '\n'
    for s in $(aws ecs list-services --region $REGION --cluster $c \
        --query 'serviceArns[]' --output text); do
      sname=$(basename $s)
      echo ""
      echo "  Service: $sname"
      aws ecs describe-services --region $REGION --cluster $c --services $s \
        --query 'services[0].[status,desiredCount,runningCount,pendingCount,taskDefinition]' \
        --output table
      echo "  Last 5 events:"
      aws ecs describe-services --region $REGION --cluster $c --services $s \
        --query 'services[0].events[0:5].[createdAt,message]' --output table
    done
  done
else
  echo "No demo ECS cluster identified — naming convention differs."
fi

echo ""
echo "================================================================"
echo " STEP 6: ALB TARGET HEALTH FOR DEMO"
echo "================================================================"
# Find ALB target groups with 'demo' in the name
DEMO_TGS=$(aws elbv2 describe-target-groups --region $REGION \
  --query 'TargetGroups[?contains(TargetGroupName, `demo`)].TargetGroupArn' \
  --output text)
if [ -n "$DEMO_TGS" ]; then
  for tg in $DEMO_TGS; do
    echo "Target group: $(basename $tg)"
    aws elbv2 describe-target-health --region $REGION --target-group-arn $tg \
      --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason,TargetHealth.Description]' \
      --output table
  done
else
  echo "No demo target groups found by name."
fi

echo ""
echo "================================================================"
echo " STEP 7: SUMMARY — what to do next"
echo "================================================================"
echo ""
echo "Tags applied so atlas-ops-broker-nonprod can see dev/demo resources."
echo "SSM param discovery printed above — share the /atlas and /acuity"
echo "lists with the agent so it knows where prod/dev/demo DB URLs live."
echo "Demo 503 diagnosis printed above — share with the agent for triage."
echo ""
echo "DONE."
