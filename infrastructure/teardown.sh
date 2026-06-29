#!/usr/bin/env bash
# =============================================================================
# Tear down the ENTIRE todo-app infrastructure (for recreate-before-review).
#
#   Usage:
#     ./teardown.sh            # asks for confirmation
#     ./teardown.sh --yes      # skip the confirmation prompt
#
#   What it does, in order:
#     1. Empties every todo-app-* S3 bucket (all object versions + delete markers)
#        and the ECR repo — these block CloudFormation stack deletion otherwise.
#     2. Deletes the parent stack  (default: "todo")          -> all nested stacks
#     3. Deletes the bootstrap stack (default: "todo-app-bootstrap")
#     4. Deletes the retained templates bucket (DeletionPolicy: Retain survives #3)
#     5. Prints a verification sweep.
#
#   It does NOT delete the account-global GitHub OIDC provider (shared, reusable).
#
#   Override any of these via environment variables if your names differ:
#     REGION, PROJECT, PARENT_STACK, BOOTSTRAP_STACK
# =============================================================================
set -uo pipefail

REGION="${REGION:-${AWS_REGION:-eu-central-1}}"
PROJECT="${PROJECT:-todo-app}"
PARENT_STACK="${PARENT_STACK:-todo}"
BOOTSTRAP_STACK="${BOOTSTRAP_STACK:-todo-app-bootstrap}"

ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" || {
  echo "ERROR: cannot resolve AWS identity. Are credentials configured?"; exit 1; }

echo "Account : $ACCOUNT"
echo "Region  : $REGION"
echo "Project : $PROJECT  (parent stack: $PARENT_STACK, bootstrap: $BOOTSTRAP_STACK)"
echo

if [ "${1:-}" != "--yes" ]; then
  read -r -p "This will PERMANENTLY DELETE all ${PROJECT} infrastructure. Type 'destroy' to continue: " ans
  [ "$ans" = "destroy" ] || { echo "Aborted."; exit 1; }
fi

# --- helpers ----------------------------------------------------------------

# Empty a versioned bucket (objects + versions + delete markers). No-op if absent.
empty_bucket() {
  local b="$1"
  aws s3api head-bucket --bucket "$b" --region "$REGION" 2>/dev/null || return 0
  echo "  emptying $b"
  while : ; do
    local payload
    payload="$(aws s3api list-object-versions --bucket "$b" --region "$REGION" --max-items 500 --output json \
      --query '{Objects: ([Versions, DeleteMarkers][] || `[]`)[].{Key:Key,VersionId:VersionId}}')"
    if echo "$payload" | grep -q '"Key"'; then
      aws s3api delete-objects --bucket "$b" --region "$REGION" --delete "$payload" >/dev/null
    else
      break
    fi
  done
}

# List all buckets whose name starts with the project prefix.
project_buckets() {
  aws s3api list-buckets --query "Buckets[?starts_with(Name, '${PROJECT}-')].Name" --output text 2>/dev/null
}

delete_stack() {
  local s="$1"
  if aws cloudformation describe-stacks --stack-name "$s" --region "$REGION" >/dev/null 2>&1; then
    echo "Deleting stack: $s (this can take 10-15 min for RDS/Redis/CloudFront)..."
    aws cloudformation delete-stack --stack-name "$s" --region "$REGION"
    if aws cloudformation wait stack-delete-complete --stack-name "$s" --region "$REGION" 2>/dev/null; then
      echo "  $s deleted."
    else
      echo "  WARN: wait timed out or failed for $s — check the console / re-run this script."
    fi
  else
    echo "Stack $s not present — skipping."
  fi
}

# --- 1. clear deletion blockers --------------------------------------------
echo
echo "== Step 1: empty buckets + ECR images =="
for b in $(project_buckets); do empty_bucket "$b"; done

if aws ecr describe-repositories --repository-names "${PROJECT}-app" --region "$REGION" >/dev/null 2>&1; then
  ids="$(aws ecr list-images --repository-name "${PROJECT}-app" --region "$REGION" --query 'imageIds[*]' --output json)"
  if [ "$ids" != "[]" ] && [ -n "$ids" ]; then
    aws ecr batch-delete-image --repository-name "${PROJECT}-app" --region "$REGION" --image-ids "$ids" >/dev/null \
      && echo "  emptied ECR repo ${PROJECT}-app"
  fi
fi

# --- 2 & 3. delete the stacks ----------------------------------------------
echo
echo "== Step 2: delete parent stack =="
delete_stack "$PARENT_STACK"

echo
echo "== Step 3: delete bootstrap stack =="
delete_stack "$BOOTSTRAP_STACK"

# --- 4. remove retained buckets (templates bucket has DeletionPolicy: Retain) -
echo
echo "== Step 4: remove any remaining ${PROJECT}-* buckets =="
for b in $(project_buckets); do
  empty_bucket "$b"
  aws s3api delete-bucket --bucket "$b" --region "$REGION" 2>/dev/null && echo "  deleted bucket $b"
done

# --- 5. verification sweep --------------------------------------------------
echo
echo "== Step 5: verification (anything listed below still exists) =="
echo -n "Stacks       : "; aws cloudformation list-stacks --region "$REGION" \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE ROLLBACK_COMPLETE DELETE_FAILED \
  --query "StackSummaries[?contains(StackName,'${PROJECT}') || StackName=='${PARENT_STACK}'].StackName" --output text 2>/dev/null | grep . || echo "none ✅"
echo -n "S3 buckets   : "; project_buckets | grep . || echo "none ✅"
echo -n "RDS          : "; aws rds describe-db-instances --region "$REGION" --query "DBInstances[?starts_with(DBInstanceIdentifier,'${PROJECT}')].DBInstanceIdentifier" --output text 2>/dev/null | grep . || echo "none ✅"
echo -n "RDS Proxy    : "; aws rds describe-db-proxies --region "$REGION" --query "DBProxies[?starts_with(DBProxyName,'${PROJECT}')].DBProxyName" --output text 2>/dev/null | grep . || echo "none ✅"
echo -n "ElastiCache  : "; aws elasticache describe-replication-groups --region "$REGION" --query "ReplicationGroups[?starts_with(ReplicationGroupId,'${PROJECT}')].ReplicationGroupId" --output text 2>/dev/null | grep . || echo "none ✅"
echo -n "ECR repo     : "; aws ecr describe-repositories --region "$REGION" --query "repositories[?starts_with(repositoryName,'${PROJECT}')].repositoryName" --output text 2>/dev/null | grep . || echo "none ✅"
echo -n "ECS clusters : "; aws ecs list-clusters --region "$REGION" --query "clusterArns[?contains(@,'${PROJECT}')]" --output text 2>/dev/null | grep . || echo "none ✅"

echo
echo "Teardown complete. (GitHub OIDC provider left intact — it is account-global and reused.)"
echo "Note: don't push to the '${PARENT_STACK}' infra branch until you re-bootstrap, or GitSync may recreate the stack."
