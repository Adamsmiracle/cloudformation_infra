# Stack Explained — todo-app

A **To-Do web app** built as a CloudFormation nested-stack system managed by
**CloudFormation GitSync**. The app runs on **ECS Fargate** behind an ALB,
stores tasks in **RDS PostgreSQL** (reached through **RDS Proxy**), caches
reads in **ElastiCache Redis**, and every image push triggers an automated
**blue/green deployment** through CodePipeline + CodeDeploy.

---

## Architecture overview

| Template | Layer | Deployed by |
|---|---|---|
| `prerequisites.yaml` (separate repo) | Prerequisites | CloudFormation GitSync — **first** |
| `templates/parent.yaml` | Orchestration | CloudFormation GitSync |
| `children/01-network.yaml` | Network | Parent nested stack |
| `children/02-security.yaml` | Security groups | Parent nested stack |
| `children/03-iam.yaml` | IAM | Parent nested stack |
| `children/04-database.yaml` | Database | Parent nested stack |
| `children/05-cache.yaml` | Cache | Parent nested stack |
| `children/06-alb-ecs.yaml` | Compute | Parent nested stack |
| `children/07-pipeline.yaml` | CI/CD | Parent nested stack |

---

## Prerequisites (`prerequisites.yaml`, separate repo)

Deployed by GitSync from its **own repository, before anything else**. Holds
the resources both CI pipelines depend on — creating them first removes the
chicken-and-egg race (the infra repo's workflow needs the bucket + role before
it can upload templates; the ECS service needs the ECR repo before its first
deploy). The template is flat, so GitSync needs no template bucket for it.

| Resource | Type | What it does |
|---|---|---|
| `TemplatesBucket` | `AWS::S3::Bucket` | Stores the child CloudFormation templates uploaded by the infra repo's GitHub Actions. Versioned, AES256-encrypted, all public access blocked. `DeletionPolicy: Retain`. |
| `TemplatesBucketPolicy` | `AWS::S3::BucketPolicy` | Denies all non-TLS access; allows `cloudformation.amazonaws.com` to read template objects (required for nested stacks). |
| `EcrRepository` | `AWS::ECR::Repository` | Registry `todo-app-app`. `MUTABLE` tags so the workflow can overwrite `latest` (the tag CodePipeline tracks). Scan-on-push, AES256, keeps last 10 images. |
| `InfraGitHubActionsRole` | `AWS::IAM::Role` | OIDC role for the **infra repo's** workflow. Trust scoped to **branch `todo` only** (`repo:…/cloudformation_infra:ref:refs/heads/todo`). Grants template upload + parent-stack change-set APIs. |
| `AppGitHubActionsRole` | `AWS::IAM::Role` | OIDC role for the **app repo's** workflow. Trust scoped to **branch `todo` only**. Grants ECR push to the repo above + deploy-bundle read/write in the deploy-source bucket. |

---

## Parent (`templates/parent.yaml`)

Pure orchestration — no AWS resources of its own. Instantiates all 7 children,
threads parameters between them via `!GetAtt <Child>.Outputs.<X>`, and bumps
`TemplateVersion` on every push to force CloudFormation to re-read nested
stacks.

| Resource | Type | What it does |
|---|---|---|
| `NetworkStack` | `AWS::CloudFormation::Stack` | Receives CIDR parameters; exports VPC id and per-tier subnet ids. |
| `SecurityStack` | `AWS::CloudFormation::Stack` | Receives VPC id/CIDR; exports ALL security-group ids. |
| `IamStack` | `AWS::CloudFormation::Stack` | Exports all application role ARNs. |
| `DatabaseStack` | `AWS::CloudFormation::Stack` | Receives data subnets + DB/proxy SG ids; exports proxy endpoint and secret ARN. |
| `CacheStack` | `AWS::CloudFormation::Stack` | Receives cache subnets + cache SG id; exports Redis endpoint. |
| `AlbEcsStack` | `AWS::CloudFormation::Stack` | Receives networking, role ARNs, ALB/service SG ids; exports ALB DNS, cluster/service names, target group names. |
| `PipelineStack` | `AWS::CloudFormation::Stack` | Receives cluster/service/TG names from `AlbEcsStack`, role ARNs from `IamStack`, ECR repo name (`${ProjectName}-app`, created in the prerequisites stack). |

---

## 01 — Network (`children/01-network.yaml`)

Multi-AZ VPC with a dedicated subnet pair per tier (public/ALB, app/ECS,
data/RDS+Proxy, cache/Redis) and **no NAT gateway** — private subnets reach
AWS services exclusively through VPC endpoints (interface: ECR api/dkr, Logs,
Secrets Manager, SSM, SSM Messages; gateway: S3 for ECR image layers).

---

## 02 — Security (`children/02-security.yaml`)

**Every security group and every rule in one file.** The whole traffic matrix
is reviewable at a glance, and no workload stack needs to reach into another
stack's groups (the old layout split SGs across the database/cache/compute
stacks and had the compute stack inject ingress rules into the others to break
dependency cycles).

| Group | Ingress | Egress |
|---|---|---|
| `AlbSecurityGroup` | :80 from internet | :8080 to tasks |
| `ServiceSecurityGroup` | :8080 from ALB | :443 endpoints + S3, :5432 to proxy, :6379 to Redis |
| `ProxySecurityGroup` | :5432 from tasks | :5432 to RDS |
| `DbSecurityGroup` | :5432 from proxy | none |
| `CacheSecurityGroup` | :6379 from tasks | none |

Cross-group rules are standalone `SecurityGroupIngress`/`Egress` resources to
avoid circular references between mutually-referencing groups.

---

## 03 — IAM (`children/03-iam.yaml`)

All **application** IAM roles in one place. Every policy scope uses
name-derived ARNs (built from `ProjectName`) so this stack has no dependency
on the compute or pipeline stacks. (The GitHub Actions OIDC roles live in the
prerequisites stack — different lifecycle.)

| Resource | Type | What it does |
|---|---|---|
| `TaskExecutionRole` | `AWS::IAM::Role` | Assumed by the **ECS agent**. Managed `AmazonECSTaskExecutionRolePolicy` — pull images from ECR, write logs. |
| `TaskRole` | `AWS::IAM::Role` | Assumed by the **running app container**. ECS Exec SSM channels; read SSM parameters under `/${ProjectName}/*`; read the `rds!db-*` Secrets Manager secret. |
| `CodeDeployRole` | `AWS::IAM::Role` | Managed `AWSCodeDeployRoleForECS` — orchestrates ECS blue/green traffic shifting. |
| `CodePipelineRole` | `AWS::IAM::Role` | Least-privilege inline policy: artifact bucket R/W, CodeDeploy deployment APIs, ECS describe/update, `iam:PassRole` to ECS tasks, ECR describe, deploy-source bucket read. |
| `EventBridgePipelineRole` | `AWS::IAM::Role` | Lets the ECR-push rule call `codepipeline:StartPipelineExecution` on this pipeline only. |

---

## 04 — Database (`children/04-database.yaml`)

RDS PostgreSQL 16 (Multi-AZ, encrypted gp3, not publicly accessible) plus
**RDS Proxy** — the app connects only to the proxy endpoint (connection
pooling, failover smoothing). `ManageMasterUserPassword: true` — Secrets
Manager generates and rotates the master password; both the proxy and the app
read that secret. Endpoint/name/secret-ARN are published to SSM under
`/${ProjectName}/…`. Security groups arrive as parameters from the security
stack.

---

## 05 — Cache (`children/05-cache.yaml`)

ElastiCache Redis 7.1 single node in the dedicated cache subnets — the app's
read cache. Encrypted at rest, endpoint + port published to SSM. Its security
group arrives as a parameter from the security stack.

---

## 06 — ALB + ECS (`children/06-alb-ecs.yaml`)

The compute layer: internet-facing ALB (blue + green target groups, HTTP :80
listener), Fargate cluster/service configured for `CODE_DEPLOY` blue/green,
CloudWatch log group, and CPU target-tracking autoscaling (min 1 / max 4,
target 60%). Creates **no security groups** — ALB and service SG ids arrive as
parameters. The initial task definition exists only so the service can be
created; CodeDeploy registers real revisions from the app repo's
`taskdef.json` afterwards.

---

## 07 — Pipeline (`children/07-pipeline.yaml`)

Fully automated CI/CD: an ECR image push triggers an end-to-end blue/green
deployment with no manual approval gate.

| Resource | Type | What it does |
|---|---|---|
| `ArtifactBucket` | `AWS::S3::Bucket` | CodePipeline's internal artifact store. Versioned, encrypted, public access blocked. |
| `DeploySourceBucket` | `AWS::S3::Bucket` | Holds `deploy-bundle.zip` (`taskdef.json` + `appspec.yaml`) uploaded by the app repo's workflow. Versioning required for the S3 source action. |
| `CodeDeployApp` / `CodeDeployDeploymentGroup` | CodeDeploy | Blue/green group wired to the ECS service and both target groups. Auto traffic shift once green is healthy; blue terminated after 5 min; auto-rollback on failure. |
| `EcrImagePushRule` | `AWS::Events::Rule` | Fires on a successful ECR `PUSH` of `latest` — the single deployment trigger. |
| `Pipeline` | `AWS::CodePipeline::Pipeline` | **Source** (parallel): ECR `latest` metadata + `deploy-bundle.zip` from S3. **Deploy**: `CodeDeployToECS` substitutes the new image digest into `IMAGE1_NAME`. |

---

## End-to-end flow

```
Prerequisites → GitSync deploys prereq repo (bucket, ECR, branch-scoped OIDC roles)

Infra change  → push to infra repo (branch todo)
              → GHA uploads child templates to TemplatesBucket
              → bumps TemplateVersion, GitSync re-deploys affected nested stacks

App change    → push to app repo (branch todo)
              → GHA builds image (Amazon Corretto), pushes `latest` to ECR
              → GHA uploads deploy-bundle.zip to DeploySourceBucket (if changed)

ECR push      → EventBridge EcrImagePushRule fires
              → CodePipeline starts
              → Source: pulls new image metadata + deploy bundle
              → Deploy: CodeDeploy blue/green on ECS service
                  green tasks start, pass health checks
                  ALB listener shifts from blue → green
                  blue tasks terminate after 5 min

User traffic  → ALB (HTTP) → ECS Fargate tasks (app subnets)
Task data     → ECS tasks → RDS Proxy → RDS PostgreSQL (data subnets)
Read cache    → ECS tasks → ElastiCache Redis (cache subnets)
Config        → ECS tasks read SSM params at startup
DB creds      → ECS tasks read Secrets Manager at startup
```
