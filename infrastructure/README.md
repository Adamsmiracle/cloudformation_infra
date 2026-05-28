# ecs-ci-cd-lab-infra

Nested-stack CloudFormation deployment for the ECS CI/CD lab. The **parent**
template is deployed by GitSync; **child** templates live in S3 and are
uploaded there by GitHub Actions in this repo.

## Architecture

```
infrastructure GitHub repo (this repo)
    │
    ├── on push → GitHub Actions
    │       │
    │       │ aws s3 sync templates/children/ → S3 templates bucket
    │       └── update-stack TemplateVersion → CFN re-evaluates parent
    │
    └── on push → GitSync (parent template only)
            │
            └── creates/updates the parent stack
                    │
                    ├── creates NetworkStack    (children/01-network.yaml)
                    ├── creates EcrStack         (children/02-ecr.yaml)
                    ├── creates AlbEcsStack      (children/03-alb-ecs.yaml)
                    └── creates PipelineStack    (children/04-pipeline.yaml)
```

## Layout

```
infrastructure/
├── 00-bootstrap.yaml           # ONE-TIME manual deploy: S3 bucket + GHA OIDC role
├── deployment.yaml             # GitSync deployment file for the parent
├── templates/
│   ├── parent.yaml             # Parent stack (referenced by GitSync)
│   └── children/
│       ├── 01-network.yaml     # VPC, subnets, route tables, VPC endpoints
│       ├── 02-ecr.yaml         # ECR repo + GitHub Actions OIDC role (app repo)
│       ├── 03-alb-ecs.yaml     # ALB, target groups, ECS Fargate, autoscaling
│       └── 04-pipeline.yaml    # EventBridge → CodePipeline → CodeDeploy
└── .github/workflows/
    └── sync-templates.yml      # Uploads children to S3 + bumps parent version
```

## One-time bootstrap

The bootstrap stack creates the S3 bucket that holds child templates and the
IAM role GitHub Actions in *this repo* assumes via OIDC. Deploy it once,
manually:

```bash
aws cloudformation deploy \
  --stack-name ecs-ci-cd-bootstrap \
  --template-file 00-bootstrap.yaml \
  --parameter-overrides GitHubOrg=adamsMiracle InfraRepoName=infra-repo \
  --capabilities CAPABILITY_NAMED_IAM \
  --region eu-central-1
```

Grab the outputs:
- `TemplatesBucketUrl` — paste into `deployment.yaml` as `TemplatesBaseUrl`
- `InfraGitHubActionsRoleArn` — set as the `INFRA_GHA_ROLE_ARN` secret in this repo's GitHub settings

## End-to-end deploy flow

1. **Bootstrap** (one-time, above) — creates the S3 bucket + OIDC role.
2. **First push to GitHub** — `.github/workflows/sync-templates.yml` runs,
   uploads child templates to S3. Parent stack doesn't exist yet, so the
   workflow logs "parent stack does not exist yet — skipping refresh" and
   exits cleanly.
3. **Set up GitSync** on the parent template:
   - CloudFormation console → Stacks → Create stack → Sync from Git
   - Repo: this repo, branch `main`, deployment file `deployment.yaml`
   - Sync role + CFN service role
4. **GitSync deploys the parent stack**, which creates the four nested
   children by pulling their templates from S3.
5. **Subsequent updates** to child templates: push to main → GitHub Actions
   re-uploads to S3 + bumps `TemplateVersion` on the parent → CFN re-evaluates
   children and applies any changes.
6. **Subsequent updates** to the parent template: GitSync handles it
   automatically (parent template change → GitSync deploys → cascades to
   children that depend on the changed parameters).

## Why the `TemplateVersion` cache-bust

Child templates are stored at stable S3 paths (`children/01-network.yaml`,
not `children/01-network-abc123.yaml`). CloudFormation **caches** nested
template URLs, so it won't notice when the body at a stable URL changes
unless something forces it to re-evaluate the parent.

The `TemplateVersion` parameter solves this: every push bumps it to a new
value, which causes CFN to consider the parent "changed" and re-pull every
child template's URL. Children whose bodies haven't changed produce no-op
updates; children whose bodies have changed get redeployed.

This is a common nested-stacks pattern. The alternative — versioned URLs
like `children/01-network-${sha}.yaml` — works too but requires the parent
template itself to change on every child push, which conflicts with the
"child changes don't touch parent" requirement.

## Preconditions

These must already exist:

| Resource | How to create |
|---|---|
| GitHub OIDC provider in IAM (`token.actions.githubusercontent.com`) | IAM console (already in your account) |
| CodeConnections connection to GitHub | Developer Tools → Connections |
| GitSync role | IAM console |
| CFN service role (for GitSync to deploy stacks) | IAM console — needs `AdministratorAccess` or scoped equivalent |

## Outputs to grab after first deploy

| Output | Description |
|---|---|
| Parent stack output `AlbDns` | Public URL of the running app |
| Parent stack output `EcrRepositoryUri` | Where the app repo's workflow pushes images |
| Parent stack output `GitHubActionsRoleArn` | Paste account ID into the app-repo workflow |
