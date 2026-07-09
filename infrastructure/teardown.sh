#!/usr/bin/env bash
set -uo pipefail

REGION="${REGION:-${AWS_REGION:-eu-central-1}}"
PROJECT="${PROJECT:-todo-app}"
PARENT_STACK="${PARENT_STACK:-todo}"
PREREQ_STACK="${PREREQ_STACK:-prereq}"

ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" || {
  echo "ERROR: cannot resolve AWS identity"; exit 1; }

echo "Account : $ACCOUNT"
echo "Region  : $REGION"
echo "Project : $PROJECT"
echo

if [ "${1:-}" != "--yes" ]; then
  read -r -p "This will DELETE ALL STACK RESOURCES for ${PROJECT}. Type 'destroy' to continue: " ans
  [ "$ans" = "destroy" ] || { echo "Aborted."; exit 1; }
fi

# -------------------------------
# Helpers
# -------------------------------

empty_bucket() {
  local b="$1"
  aws s3api head-bucket --bucket "$b" --region "$REGION" 2>/dev/null || return 0

  echo "  emptying bucket: $b"

  while : ; do
    payload="$(aws s3api list-object-versions \
      --bucket "$b" \
      --region "$REGION" \
      --max-items 500 \
      --output json \
      --query '{Objects: ([Versions, DeleteMarkers][] || `[]`)[].{Key:Key,VersionId:VersionId}}')"

    if echo "$payload" | grep -q '"Key"'; then
      aws s3api delete-objects \
        --bucket "$b" \
        --region "$REGION" \
        --delete "$payload" >/dev/null
    else
      break
    fi
  done
}

project_buckets() {
  aws s3api list-buckets \
    --query "Buckets[?starts_with(Name, '${PROJECT}-')].Name" \
    --output text 2>/dev/null
}

delete_stack() {
  local s="$1"

  if aws cloudformation describe-stacks --stack-name "$s" --region "$REGION" >/dev/null 2>&1; then
    echo "Deleting stack: $s"
    aws cloudformation delete-stack --stack-name "$s" --region "$REGION"

    aws cloudformation wait stack-delete-complete \
      --stack-name "$s" \
      --region "$REGION" || {
        echo "WARN: stack delete wait failed for $s (check console)"
      }
  else
    echo "Stack not found: $s"
  fi
}

# -------------------------------
# STEP 1: Delete app resources
# -------------------------------

echo
echo "== Step 1: Empty S3 + ECR =="

for b in $(project_buckets); do
  empty_bucket "$b"
done

if aws ecr describe-repositories --repository-names "${PROJECT}-app" --region "$REGION" >/dev/null 2>&1; then
  echo "  clearing ECR repo..."

  ids="$(aws ecr list-images \
    --repository-name "${PROJECT}-app" \
    --region "$REGION" \
    --query 'imageIds[*]' \
    --output json)"

  if [ "$ids" != "[]" ] && [ -n "$ids" ]; then
    aws ecr batch-delete-image \
      --repository-name "${PROJECT}-app" \
      --region "$REGION" \
      --image-ids "$ids" >/dev/null
  fi
fi

# -------------------------------
# STEP 2: Delete CloudFormation stacks ONLY
# -------------------------------

echo
echo "== Step 2: Delete CloudFormation stacks =="

delete_stack "$PARENT_STACK"
delete_stack "$PREREQ_STACK"

# -------------------------------
# IMPORTANT NOTE (Git Sync)
# -------------------------------

echo
echo "== Git Sync Policy =="

echo "IMPORTANT:"
echo "- Git Sync configuration is intentionally NOT deleted."
echo "- It is a persistent deployment trigger tied to your repo + branch."
echo "- This allows safe teardown/recreate cycles without 409 conflicts."
echo "- The prerequisites stack ('$PREREQ_STACK') is GitSync-managed from the"
echo "  prerequisites repo — a push there recreates it before the main infra."
echo

# -------------------------------
# STEP 3: Verification
# -------------------------------

echo
echo "== Step 3: Verification =="

echo -n "Stacks       : "
aws cloudformation list-stacks --region "$REGION" \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE ROLLBACK_COMPLETE DELETE_FAILED \
  --query "StackSummaries[?contains(StackName,'${PROJECT}') || StackName=='${PARENT_STACK}'].StackName" \
  --output text 2>/dev/null | grep . || echo "none ✅"

echo -n "S3 buckets   : "
project_buckets | grep . || echo "none ✅"

echo -n "ECR repo     : "
aws ecr describe-repositories --region "$REGION" \
  --query "repositories[?starts_with(repositoryName,'${PROJECT}')].repositoryName" \
  --output text 2>/dev/null | grep . || echo "none ✅"

echo -n "ECS clusters : "
aws ecs list-clusters --region "$REGION" \
  --query "clusterArns[?contains(@,'${PROJECT}')]" \
  --output text 2>/dev/null | grep . || echo "none ✅"

echo

echo "Teardown complete."
echo "Git Sync remains active → push to branch will automatically recreate infrastructure."