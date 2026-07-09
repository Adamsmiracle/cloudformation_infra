# todo-lab-infra

Nested-stack CloudFormation deployment for the ECS CI/CD lab. The **parent**
template is deployed by GitSync; **child** templates live in S3 and are
uploaded there by GitHub Actions in this repo.

**Deploy order:** the separate **prerequisites repo** goes first (GitSync).
It creates the templates S3 bucket, the ECR repository, and both GitHub
Actions OIDC roles (branch-scoped) — everything this repo's CI and the app
repo's CI need before they can run. That ordering removes the chicken-and-egg
race between the pipelines and the infrastructure they depend on.

## Architecture

```
prerequisites GitHub repo (separate repo)
    │
    └── on push → GitSync (flat template, no bucket needed)
            └── creates todo-app-prereqs stack
                    ├── S3 templates bucket
                    ├── ECR repository (todo-app-app)
                    ├── infra GHA OIDC role   (branch todo only)
                    └── app GHA OIDC role     (branch todo only)

infrastructure GitHub repo (this repo)
    │
    ├── on push → GitHub Actions
    │       │
    │       │ aws s3 sync templates/ → S3 templates bucket
    │       └── bump TemplateVersion → CFN re-evaluates parent
    │
    └── on push → GitSync (parent template only)
            │
            └── creates/updates the parent stack
                    │
                    ├── creates NetworkStack    (children/01-network.yaml)
                    ├── creates SecurityStack   (children/02-security.yaml)
                    ├── creates IamStack        (children/03-iam.yaml)
                    ├── creates DatabaseStack   (children/04-database.yaml)
                    ├── creates CacheStack      (children/05-cache.yaml)
                    ├── creates AlbEcsStack     (children/06-alb-ecs.yaml)
                    └── creates PipelineStack   (children/07-pipeline.yaml)
```

## Layout

```
infrastructure/
├── deployment.yaml             # GitSync deployment file for the parent
├── templates/
│   ├── parent.yaml             # Parent stack (referenced by GitSync)
│   └── children/
│       ├── 01-network.yaml     # VPC, subnets, route tables, VPC endpoints
│       ├── 02-security.yaml    # ALL security groups + rules (one file)
│       ├── 03-iam.yaml         # ALL application IAM roles (consolidated)
│       ├── 04-database.yaml    # RDS PostgreSQL (Multi-AZ) + RDS Proxy + Secrets Manager
│       ├── 05-cache.yaml       # ElastiCache Redis read cache
│       ├── 06-alb-ecs.yaml     # ALB, target groups, ECS Fargate, autoscaling
│       └── 07-pipeline.yaml    # EventBridge → CodePipeline → CodeDeploy
└── .github/workflows/
    └── sync-infra-templates.yml # Uploads templates to S3 + bumps parent version
```

The ECR repository, templates bucket, and GitHub OIDC roles are **not** here —
they live in the prerequisites repo (different lifecycle: they must exist
before either CI workflow can run).

## Prerequisites stack (separate repo, deploy FIRST)

Connect the prerequisites repo to CloudFormation GitSync (stack name
`todo-app-prereqs`, deployment file `deployment.yaml`). Then grab its outputs:

- `TemplatesBucketUrl` — paste into this repo's `deployment.yaml` as `TemplatesBaseUrl`
- `TemplatesBucketName` — set as the `TODO_TEMPLATES_BUCKET` secret in this repo
- `InfraGitHubActionsRoleArn` — set as the `TODO_INFRA_GHA_ROLE_ARN` secret in this repo
- `AppGitHubActionsRoleArn` — set as the `AWS_ROLE_ARN_TODO` secret in the app repo

Both OIDC roles are scoped to the `todo` **branch** of their repo (not the
whole repo): `repo:<org>/<repo>:ref:refs/heads/todo`.

## End-to-end deploy flow

1. **Prerequisites** (separate repo, above) — GitSync creates the bucket, ECR,
   and OIDC roles.
2. **First push to this repo** — `.github/workflows/sync-infra-templates.yml`
   runs and uploads the templates to S3.
3. **Set up GitSync** on the parent template:
   - CloudFormation console → Stacks → Create stack → Sync from Git
   - Repo: this repo, branch `todo`, deployment file `infrastructure/deployment.yaml`
   - Sync role + CFN service role
4. **GitSync deploys the parent stack**, which creates the seven nested
   children by pulling their templates from S3.
5. **Subsequent updates** to child templates: push to `todo` → GitHub Actions
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
| CodeConnections connection to GitHub (**for GitSync only** — the pipeline no longer uses one; it reads the deploy bundle from S3) | Developer Tools → Connections |
| GitSync role | IAM console |
| CFN service role (for GitSync to deploy stacks) | IAM console — needs `AdministratorAccess` or scoped equivalent |

## Outputs to grab after first deploy

| Output | Description |
|---|---|
| Parent stack output `AlbDns` | Public URL of the running app |
| Prereq stack output `EcrRepositoryUri` | Where the app repo's workflow pushes images |
| Prereq stack output `AppGitHubActionsRoleArn` | Set as `AWS_ROLE_ARN_TODO` secret in the app repo |
