#!/usr/bin/env bash
# =============================================================================
# Recreate the todo-app infrastructure and let CloudFormation GitSync deploy it.
#
#   Usage:  ./recreate.sh            (run from anywhere; resolves its own paths)
#
#   It performs the scriptable prerequisites GitSync needs, then triggers /
#   guides the GitSync deployment:
#
#     1. Deploy the bootstrap stack        -> templates S3 bucket + infra OIDC role
#     2. Make sure deployment.yaml's TemplatesBaseUrl matches that bucket
#     3. Full-sync templates/ to the bucket  (so GitSync can instantiate the
#        nested stacks on its very first run — avoids the upload/deploy race)
#     4a. If the parent stack is ALREADY GitSync-linked: bump TemplateVersion,
#         commit + push to the branch -> GitSync redeploys. Then poll.
#     4b. If it is NOT linked (the usual case after a full teardown): print the
#         one-time console steps to link GitSync, then poll until it appears.
#
#   GitSync's repo connection (CodeConnections) and sync configuration cannot be
#   created via the CLI, so 4b is unavoidable on a fresh recreate. The CodeConnections
#   connection itself persists across teardowns, so re-linking is quick.
#
#   Override via env vars if names differ: REGION PROJECT PARENT_STACK BOOTSTRAP_STACK BRANCH
# =============================================================================
set -uo pipefail

REGION="${REGION:-${AWS_REGION:-eu-central-1}}"
PROJECT="${PROJECT:-todo-app}"
PARENT_STACK="${PARENT_STACK:-todo}"
BOOTSTRAP_STACK="${BOOTSTRAP_STACK:-todo-app-bootstrap}"
BRANCH="${BRANCH:-todo}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # infrastructure/
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"                    # infra repo root
DEPLOY_FILE="$SCRIPT_DIR/deployment.yaml"

ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" || {
  echo "ERROR: cannot resolve AWS identity. Configure credentials first."; exit 1; }
BUCKET="${PROJECT}-cfn-templates-${ACCOUNT}-${REGION}"
DEPLOY_FILE_REL="infrastructure/deployment.yaml"

echo "Account : $ACCOUNT"
echo "Region  : $REGION"
echo "Project : $PROJECT  (parent stack: $PARENT_STACK, branch: $BRANCH)"
echo "Bucket  : $BUCKET"
echo

# --- 1. bootstrap ----------------------------------------------------------
echo "== Step 1: deploy bootstrap stack =="
aws cloudformation deploy \
  --template-file "$SCRIPT_DIR/00-bootstrap.yaml" \
  --stack-name "$BOOTSTRAP_STACK" \
  --parameter-overrides ProjectName="$PROJECT" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region "$REGION" || { echo "  bootstrap deploy reported no-op or error (continuing)"; }

# --- 2. verify deployment.yaml points at this bucket -----------------------
echo
echo "== Step 2: verify TemplatesBaseUrl =="
EXPECTED_URL="https://s3.${REGION}.amazonaws.com/${BUCKET}"
if grep -q "TemplatesBaseUrl: ${EXPECTED_URL}\b" "$DEPLOY_FILE"; then
  echo "  OK -> $EXPECTED_URL"
else
  echo "  WARNING: deployment.yaml TemplatesBaseUrl does not match $EXPECTED_URL"
  echo "           current: $(grep TemplatesBaseUrl "$DEPLOY_FILE" || true)"
  echo "           fix it before GitSync runs, or the nested stacks won't resolve."
fi

# --- 3. populate S3 so GitSync's first run finds the children --------------
echo
echo "== Step 3: sync templates to S3 =="
aws s3 sync "$SCRIPT_DIR/templates/" "s3://${BUCKET}/" --delete --region "$REGION"

# --- helper: poll a stack until it reaches a terminal state ----------------
wait_for_stack() {
  local s="$1" timeout="${2:-2400}" waited=0 status
  while [ "$waited" -lt "$timeout" ]; do
    status="$(aws cloudformation describe-stacks --stack-name "$s" --region "$REGION" \
      --query 'Stacks[0].StackStatus' --output text 2>/dev/null)"
    case "$status" in
      CREATE_COMPLETE|UPDATE_COMPLETE) echo; echo "  $s: $status ✅"; return 0 ;;
      *ROLLBACK_COMPLETE|*FAILED)      echo; echo "  $s: $status ❌ (check the console / nested stack events)"; return 1 ;;
      *)                               printf '.' ;;
    esac
    sleep 20; waited=$((waited + 20))
  done
  echo; echo "  timed out waiting for $s"; return 2
}

# --- 4. trigger or guide GitSync -------------------------------------------
echo
echo "== Step 4: GitSync deployment =="
if aws cloudformation describe-stacks --stack-name "$PARENT_STACK" --region "$REGION" >/dev/null 2>&1; then
  echo "  Parent stack '$PARENT_STACK' exists and is GitSync-managed — triggering a redeploy via push."
  TS="$(date -u +%Y%m%d%H%M%S)"
  sed -i "s/^  TemplateVersion:.*/  TemplateVersion: recreate-${TS}/" "$DEPLOY_FILE"
  git -C "$REPO_ROOT" add "$DEPLOY_FILE_REL"
  git -C "$REPO_ROOT" commit -m "chore: trigger gitsync recreate (${TS})" >/dev/null
  git -C "$REPO_ROOT" push origin "$BRANCH"
  echo "  Pushed. Waiting for GitSync to apply the update..."
  wait_for_stack "$PARENT_STACK"
else
  cat <<EOF
  Parent stack '$PARENT_STACK' is NOT present, so GitSync isn't linked yet.
  Link it once in the console (the CodeConnections GitHub connection persists,
  so this is fast) — CloudFormation will then create the stack from deployment.yaml:

    CloudFormation console -> Create stack -> "Sync from Git"
      Stack name      : $PARENT_STACK
      Connection      : your existing GitHub (CodeConnections) connection
      Repository      : Adamsmiracle/cloudformation_infra
      Branch          : $BRANCH
      Deployment file : $DEPLOY_FILE_REL
      Deployment role : the CloudFormation Git-sync role (let the console create one
                        with enough permissions to provision all resources)

  Templates are already in s3://$BUCKET, so the first sync will resolve the nested stacks.
  Waiting for the stack to appear (finish the wizard in the console)...
EOF
  wait_for_stack "$PARENT_STACK"
fi

echo
echo "Done. App image: after the stack is up, push the app repo to '$BRANCH' so the"
echo "pipeline builds + pushes to ECR; autoscaling then brings the ECS task up."
