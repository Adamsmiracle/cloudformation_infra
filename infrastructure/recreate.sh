#!/usr/bin/env bash
# =============================================================================
# Recreate the todo infrastructure and let CloudFormation GitSync deploy it.
#
#   Usage:  ./recreate.sh            (run from anywhere; resolves its own paths)
#
#   Steps:
#     1. Verify the PREREQUISITES stack exists (separate repo, GitSync-deployed:
#        templates bucket + ECR + GitHub OIDC roles) and its bucket is present
#     2. Verify deployment.yaml's TemplatesBaseUrl matches that bucket
#     3. Full-sync templates/ to the bucket  (so GitSync can instantiate the
#        nested stacks — avoids the upload/deploy race)
#     4. Ensure the GitSync sync configuration exists (it survives teardown; if
#        missing, guide the one-time console link and poll until it appears)
#     5. Sync with origin, bump TemplateVersion, push -> GitSync deploys the real
#        parent.yaml (all nested stacks). Then verify the nested stacks exist.
#
#   GitSync's repo connection (CodeConnections) cannot be created via the CLI,
#   so the one-time console link in step 4 is unavoidable on a fresh recreate.
#   The connection persists across teardowns, so re-linking is rarely needed.
#
#   Override via env vars if names differ: REGION PROJECT PARENT_STACK PREREQ_STACK BRANCH
# =============================================================================
set -uo pipefail

REGION="${REGION:-${AWS_REGION:-eu-central-1}}"
PROJECT="${PROJECT:-todo-app}"
PARENT_STACK="${PARENT_STACK:-todo-app}"
PREREQ_STACK="${PREREQ_STACK:-todo-app-prereqs}"
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

# --- 1. prerequisites ------------------------------------------------------
# The prerequisites stack (templates bucket + ECR + GitHub OIDC roles) lives in
# its OWN repo and is deployed by GitSync — this script does not create it.
echo "== Step 1: verify prerequisites stack =="
if aws cloudformation describe-stacks --stack-name "$PREREQ_STACK" --region "$REGION" >/dev/null 2>&1; then
  echo "  OK -> $PREREQ_STACK"
else
  cat <<EOF
  ERROR: prerequisites stack '$PREREQ_STACK' not found.
  Deploy it first from the prerequisites repo via GitSync:

    CloudFormation console -> Create stack -> "Sync from Git"
      Stack name      : $PREREQ_STACK
      Repository      : the prerequisites repo
      Branch          : $BRANCH
      Deployment file : deployment.yaml

  Then re-run this script.
EOF
  exit 1
fi

# --- 1b. guarantee the templates bucket actually exists --------------------
# A partial teardown can leave the prereq stack PRESENT but its (retained)
# bucket deleted. In that drifted state the sync in step 3 would fail with
# NoSuchBucket and every nested stack would fail with "bucket does not exist".
echo
echo "== Step 1b: verify templates bucket exists =="
if aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null; then
  echo "  OK -> $BUCKET"
else
  echo "  ERROR: bucket '$BUCKET' MISSING (drifted prerequisites stack)."
  echo "  Recreate it from the prerequisites repo (delete the '$PREREQ_STACK' stack,"
  echo "  then push to the prereq repo so GitSync redeploys it), then re-run."
  exit 1
fi

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

# --- 4. ensure the GitSync sync configuration exists -----------------------
# GitSync deploys on push ONLY if a CodeConnections sync configuration exists.
# That config survives a stack teardown, so detect it (not the stack). If it is
# missing, link it once via the console wizard (the GitHub connection persists).
echo
echo "== Step 4: ensure GitSync is linked =="
if aws codeconnections get-sync-configuration --sync-type CFN_STACK_SYNC \
     --resource-name "$PARENT_STACK" --region "$REGION" >/dev/null 2>&1; then
  echo "  sync configuration for '$PARENT_STACK' already present."
else
  cat <<EOF
  No GitSync sync configuration found for '$PARENT_STACK'. Link it once:

    CloudFormation console -> Create stack -> "Sync from Git"
      Stack name      : $PARENT_STACK
      Connection      : your existing GitHub (CodeConnections) connection
      Repository      : Adamsmiracle/cloudformation_infra
      Branch          : $BRANCH
      Deployment file : $DEPLOY_FILE_REL
      Deployment role : let the console create the CloudFormation Git-sync role

  (The wizard first creates a small "setup" stub stack — that's expected; the
  next step pushes a commit so GitSync deploys the real template.)
EOF
  printf "  Waiting for the sync configuration to appear (finish the wizard)"
  waited=0
  until aws codeconnections get-sync-configuration --sync-type CFN_STACK_SYNC \
          --resource-name "$PARENT_STACK" --region "$REGION" >/dev/null 2>&1; do
    printf '.'; sleep 15; waited=$((waited + 15))
    if [ "$waited" -ge 900 ]; then echo; echo "  timed out — re-run after linking."; exit 1; fi
  done
  echo; echo "  sync configuration detected."
fi

# --- 5. push a commit so GitSync deploys the REAL parent template ----------
# A new commit on the branch is what makes GitSync apply parent.yaml (the 7
# nested stacks) — without it, a freshly-linked stack stays as the setup stub.
echo
echo "== Step 5: deploy parent + nested stacks via GitSync (push) =="
# Sync with origin FIRST so our bump lands on top of any commit the GitHub Action
# already pushed (it auto-bumps TemplateVersion on template changes). This avoids
# the diverged-history / rebase-conflict loop.
echo "  syncing local branch with origin/$BRANCH ..."
if ! git -C "$REPO_ROOT" pull --rebase --autostash origin "$BRANCH"; then
  echo "  ERROR: 'git pull --rebase' hit a conflict. Aborting it — resolve manually, then re-run."
  git -C "$REPO_ROOT" rebase --abort 2>/dev/null || true
  exit 1
fi
TS="$(date -u +%Y%m%d%H%M%S)"
sed -i "s/^  TemplateVersion:.*/  TemplateVersion: recreate-${TS}/" "$DEPLOY_FILE"
git -C "$REPO_ROOT" add "$DEPLOY_FILE_REL"
git -C "$REPO_ROOT" commit -m "chore: trigger gitsync deploy (${TS})" >/dev/null 2>&1 \
  || echo "  (no deployment.yaml change to commit)"
git -C "$REPO_ROOT" push origin "$BRANCH"
echo "  Pushed. Waiting for GitSync to deploy the full stack..."
wait_for_stack "$PARENT_STACK"

# Verify the real template (the AWS::CloudFormation::Stack children) was applied,
# not just the GitSync setup stub (which has 0 nested stacks).
NESTED="$(aws cloudformation describe-stack-resources --stack-name "$PARENT_STACK" --region "$REGION" \
  --query "length(StackResources[?ResourceType=='AWS::CloudFormation::Stack'])" --output text 2>/dev/null)"
echo
if [ -z "$NESTED" ] || [ "$NESTED" = "0" ] || [ "$NESTED" = "None" ]; then
  echo "WARNING: 0 nested stacks — the stack still holds only the GitSync setup stub."
  echo "  Check CloudFormation console -> '$PARENT_STACK' -> 'Git sync' tab for the sync"
  echo "  status, confirm the children are in s3://$BUCKET, then push another commit."
else
  echo "Nested stacks created/updated: $NESTED ✅"
fi

echo
echo "Done. App image: after the stack is up, push the app repo to '$BRANCH' so the"
echo "pipeline builds + pushes to ECR; autoscaling then brings the ECS task up."
