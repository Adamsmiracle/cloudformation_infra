# Architecture Documentation — ECS CI/CD Lab (To-Do App)

**Lab:** Highly Available, Secure, Containerized Fullstack Java Web Application on Amazon ECS Fargate
**Region:** Single AWS Region — `eu-central-1` (multi-AZ)
**Infrastructure-as-Code:** AWS CloudFormation with GitSync (two repos: prerequisites, then infrastructure)
**CI/CD Authentication:** OIDC only, branch-scoped (no long-lived AWS secrets)

Per-resource detail lives in [infrastructure/STACK-EXPLAINED.md](infrastructure/STACK-EXPLAINED.md).
The rendered diagram lives in [infrastructure/architecture-diagram.drawio](infrastructure/architecture-diagram.drawio).

---

## 1. Architecture Overview

The lab delivers a fullstack Java (Spring Boot) to-do application on ECS
Fargate with three fully automated paths:

| Path | Trigger | What happens |
|---|---|---|
| **Prerequisites path** | Push to the prereq repo → GitSync | Deploys the flat prerequisites stack: templates S3 bucket, ECR repository, and both branch-scoped GitHub OIDC roles. Deployed **before** everything else — it breaks the chicken-and-egg race between the CI workflows and the resources they need. |
| **Infra path** | Push to the infra repo (branch `todo`) → GitHub Actions | Child templates are uploaded to the templates bucket; `TemplateVersion` is bumped; GitSync updates the parent stack, which cascades to the nested stacks. |
| **App path** | Push to the app repo (branch `todo`) → GitHub Actions | The image is built with **Amazon Corretto 21** and pushed to ECR (`latest`); the deploy bundle (`taskdef.json` + `appspec.yaml`) is uploaded to S3 when changed; the ECR push event fires EventBridge → CodePipeline → CodeDeploy blue/green swap on the ECS service. |

All AWS interactions from GitHub Actions use OIDC (`AssumeRoleWithWebIdentity`),
and each role's trust policy is pinned to **one branch** of one repo.

---

## 2. Stack Hierarchy

```
Prerequisites Stack (prerequisites.yaml)     ← separate repo, GitSync, deployed FIRST
└── creates: templates bucket + ECR repo + infra & app GHA OIDC roles (branch-scoped)

Parent Stack (parent.yaml)                   ← this repo, CloudFormation GitSync
├── NetworkStack   → children/01-network.yaml    (VPC, per-tier subnets, endpoints)
├── SecurityStack  → children/02-security.yaml   (ALL security groups + rules)
├── IamStack       → children/03-iam.yaml        (all application IAM roles)
├── DatabaseStack  → children/04-database.yaml   (RDS PostgreSQL + RDS Proxy)
├── CacheStack     → children/05-cache.yaml      (ElastiCache Redis)
├── AlbEcsStack    → children/06-alb-ecs.yaml    (ALB + ECS Fargate + autoscaling)
└── PipelineStack  → children/07-pipeline.yaml   (CodePipeline + CodeDeploy + EventBridge)
```

Grouping principle: **one layer per lifecycle and concern**. Networking,
security groups, and IAM are foundational layers consumed by everything else;
workload layers (database, cache, compute) never define each other's security
groups; the pipeline layer only wires together names/ARNs produced elsewhere.

The parent receives outputs from each child via
`!GetAtt <ChildStack>.Outputs.<Key>` and passes them as parameters to
downstream children.

---

## 3. Parameter Flow

```
Parent
 ├─ NetworkStack
 │    Outputs: VpcId, VpcCidr, PublicSubnet1/2, AppSubnet1/2,
 │             DataSubnet1/2, CacheSubnet1/2
 │
 ├─ SecurityStack
 │    Inputs FROM NetworkStack: VpcId, VpcCidr
 │    Outputs: AlbSecurityGroupId, ServiceSecurityGroupId,
 │             ProxySecurityGroupId, DbSecurityGroupId, CacheSecurityGroupId
 │
 ├─ IamStack
 │    (name-derived ARNs only — no cross-stack inputs)
 │    Outputs: TaskExecutionRoleArn, TaskRoleArn, CodeDeployRoleArn,
 │             CodePipelineRoleArn, EventBridgePipelineRoleArn
 │
 ├─ DatabaseStack
 │    Inputs FROM NetworkStack:  DataSubnet1/2
 │    Inputs FROM SecurityStack: DbSecurityGroupId, ProxySecurityGroupId
 │    Outputs: DbProxyEndpoint, DbSecretArn, …
 │
 ├─ CacheStack
 │    Inputs FROM NetworkStack:  CacheSubnet1/2
 │    Inputs FROM SecurityStack: CacheSecurityGroupId
 │    Outputs: RedisPrimaryEndpoint, RedisPort
 │
 ├─ AlbEcsStack
 │    Inputs FROM NetworkStack:  VpcId, PublicSubnet1/2, AppSubnet1/2
 │    Inputs FROM SecurityStack: AlbSecurityGroupId, ServiceSecurityGroupId
 │    Inputs FROM IamStack:      TaskExecutionRoleArn, TaskRoleArn
 │    Outputs: AlbDnsName, ClusterName, ServiceName,
 │             TargetGroupBlue/GreenName, HttpListenerArn
 │
 └─ PipelineStack
      Inputs FROM AlbEcsStack: ClusterName, ServiceName, TG names, listener ARN
      Inputs FROM IamStack:    CodeDeploy/CodePipeline/EventBridge role ARNs
      Inputs FROM parent:      EcrRepositoryName (= ${ProjectName}-app,
                               created in the prerequisites stack)
```

The app itself is configured at runtime from **SSM Parameter Store**
(`/todo-app/db-endpoint`, `/todo-app/db-name`, `/todo-app/db-secret-arn`,
`/todo-app/redis-endpoint`, `/todo-app/redis-port`) and reads DB credentials
from the Secrets Manager secret RDS manages — nothing environment-specific is
baked into the image.

---

## 4. End-to-End Workflows

### 4.1 Infrastructure Update Workflow

```
Developer pushes to infra repo (todo branch)
    │
    ▼
GitHub Actions: sync-infra-templates.yml
    ├─ 1. Assume InfraGitHubActionsRole via OIDC (trust: todo branch only)
    ├─ 2. aws s3 sync infrastructure/templates/ → templates bucket (--delete)
    ├─ 3. Bump TemplateVersion in deployment.yaml (sha-<short-commit>)
    └─ 4. Commit + push the bump
            │
            ▼
        GitSync detects the deployment.yaml change
            │
            ▼
        Parent stack update → TemplateVersion propagates to every child →
        CloudFormation re-reads child templates from S3 → changed children update
```

### 4.2 Application Build & Deploy Workflow

```
Developer pushes to app repo (todo branch)
    │
    ▼
GitHub Actions: ecs-ci-cd-workflow.yaml
    ├─ 1. Assume AppGitHubActionsRole via OIDC (trust: todo branch only)
    ├─ 2. Publish deploy-bundle.zip (taskdef.json + appspec.yaml) to the
    │      deploy-source bucket — only when the content hash changed
    ├─ 3. Build the image (multi-stage Dockerfile, Amazon Corretto 21)
    └─ 4. Push <account>.dkr.ecr…/todo-app-app:latest
            │
            ▼
        EventBridge EcrImagePushRule (PUSH + SUCCESS + tag=latest)
            │  StartPipelineExecution
            ▼
        CodePipeline
            ├─ Source: ECR image metadata (imageDetail.json)
            │        + deploy-bundle.zip from S3
            └─ Deploy: CodeDeployToECS
                    ├─ register new task definition (image digest substituted
                    │  into <IMAGE1_NAME>)
                    ├─ start green tasks → TargetGroupGreen
                    ├─ wait for ALB health checks (HTTP 200 on /)
                    ├─ shift listener traffic blue → green (no approval gate)
                    ├─ wait 5 minutes, then terminate blue tasks
                    └─ auto-rollback to blue on failure
```

---

## 5. Security Design

| Control | Implementation | Why |
|---|---|---|
| **No long-lived secrets** | All GitHub Actions use OIDC (`AssumeRoleWithWebIdentity`). | Eliminates the primary credential-leak risk in CI/CD. |
| **OIDC pinned to one branch** | `token.actions.githubusercontent.com:sub = repo:<org>/<repo>:ref:refs/heads/todo` (StringEquals) on both roles. | A workflow on any other branch, tag, or PR ref — or any other repo — cannot assume the roles. |
| **All security groups in one stack** | `02-security.yaml` owns every group and every rule. | The complete traffic matrix is auditable in a single file; workload stacks cannot quietly widen each other's ingress. |
| **DB reachable only via RDS Proxy** | tasks→proxy :5432, proxy→DB :5432; no task→DB rule exists. | Connection pooling + failover smoothing, and the DB never accepts app connections directly. |
| **ECS tasks in private subnets** | `AssignPublicIp: DISABLED`; no NAT; VPC endpoints for ECR/Logs/Secrets/SSM; S3 gateway endpoint for image layers. | Tasks are unreachable from the internet and their AWS traffic never leaves the AWS network. |
| **ALB is the sole public entry point** | ALB SG allows :80 from internet; service SG allows :8080 from ALB SG only. | Defense in depth — no direct path to containers. |
| **Dedicated subnets per tier** | public / app / data / cache subnet pairs across two AZs. | Layer-3 separation on top of the SG (layer-4) rules. |
| **Managed, rotated DB credentials** | `ManageMasterUserPassword: true`; proxy and task role read the secret; secret never appears in templates, env vars, or CI. | No human ever handles the DB password. |
| **S3 buckets: TLS-only + no public access** | `DenyInsecureTransport` policies + full `PublicAccessBlockConfiguration` on all buckets. | Templates and artifacts can't be read unencrypted or exposed publicly. |
| **Image scanning on push** | `ScanOnPush: true` on ECR. | CVEs surface immediately after build. |
| **Blue/green auto-rollback** | `AutoRollbackConfiguration` on failure/alarm; traffic returns to blue. | A bad deployment reverts automatically. |
| **Event-driven pipeline trigger** | EventBridge rule scoped to one repo + tag; role grants only `StartPipelineExecution`. | No polling, no broad permissions in the app workflow. |
| **ECS Exec via SSM** | `EnableExecuteCommand: true` + SSM endpoints + task-role SSM channel permissions. | Debug shell without SSH, bastions, or open ports. |
| **Least-privilege IAM** | Every role scopes to specific name-derived ARNs where the API allows. | Limits blast radius. |

---

## 6. Application S3 usage (photo-upload extension)

When the app is extended to store user photos in S3 (see
`photo-uploader-architecture.drawio` at the workspace root), the app must
**not** proxy image bytes through the container. Instead it generates
**presigned URLs** with its task role:

- **Upload:** app returns a presigned `PUT` URL (short expiry, content-type
  constrained); the browser uploads directly to the private bucket.
- **Download:** app returns presigned `GET` URLs for the gallery; the browser
  fetches directly from S3.

The bucket stays fully private (no public access, no bucket policy holes);
the only credentials involved are the task role's, and they never leave the
container — the browser only ever holds a time-limited signed URL. This also
keeps large image traffic off the ALB/Fargate data path.
