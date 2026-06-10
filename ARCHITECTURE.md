# Architecture Documentation — ECS CI/CD Lab

**Lab:** Highly Available, Secure, Containerized Fullstack Java Web Application on Amazon ECS Fargate  
**Region:** Single AWS Region — `eu-central-1` (multi-AZ)  
**Infrastructure-as-Code:** AWS CloudFormation with GitSync  
**CI/CD Authentication:** OIDC only (no long-lived AWS secrets)

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Stack Hierarchy](#2-stack-hierarchy)
3. [Resource Inventory](#3-resource-inventory)
   - [Bootstrap Stack](#31-bootstrap-stack-00-bootstrapyaml)
   - [Network Stack](#32-network-stack-01-networkyaml)
   - [ECR Stack](#33-ecr-stack-02-ecryaml)
   - [ALB + ECS Stack](#34-alb--ecs-stack-03-alb-ecsyaml)
   - [Pipeline Stack](#35-pipeline-stack-04-pipelineyaml)
4. [How Resources Are Linked](#4-how-resources-are-linked)
5. [End-to-End Workflows](#5-end-to-end-workflows)
6. [Architecture Diagram](#6-architecture-diagram)
7. [Security Design](#7-security-design)

---

## 1. Architecture Overview

The lab delivers a fullstack Java web application running on AWS ECS Fargate with two fully automated paths:

| Path | Trigger | What happens |
|---|---|---|
| **Infra path** | Push to `infra-repo` → GitHub Actions | Child templates are uploaded to S3; `deployment.yaml` is bumped; CloudFormation GitSync picks up the change and updates the nested stacks |
| **App path** | Push to `app-repo` → GitHub Actions | Docker image is built and pushed to ECR (tagged `<sha>` and `latest`); the ECR push event fires an EventBridge rule that starts CodePipeline; the pipeline pulls the image from ECR, a CodeBuild stage generates `taskdef.json` + `appspec.yaml`, and CodeDeploy performs a blue/green swap on the ECS service |

All AWS interactions from GitHub Actions use OIDC (`AssumeRoleWithWebIdentity`). No long-lived access keys exist anywhere in the CI/CD chain.

---

## 2. Stack Hierarchy

```
Bootstrap Stack (00-bootstrap.yaml)          ← deployed once, manually
└── creates: S3 templates bucket + infra GHA OIDC role

Parent Stack (parent.yaml)                   ← managed by CloudFormation GitSync
├── NetworkStack   → children/01-network.yaml
├── EcrStack       → children/02-ecr.yaml
├── AlbEcsStack    → children/03-alb-ecs.yaml
└── PipelineStack  → children/04-pipeline.yaml
```

The parent receives outputs from each child via `!GetAtt <ChildStack>.Outputs.<Key>` and passes them as parameters to downstream children.

---

## 3. Resource Inventory

### 3.1 Bootstrap Stack (`00-bootstrap.yaml`)

Deployed **once, manually** before GitSync is set up. Its job is to create the prerequisites that every other stack depends on.

| Resource (logical ID) | AWS Type | Why it exists |
|---|---|---|
| `TemplatesBucket` | `AWS::S3::Bucket` | Holds all child CloudFormation template files. The parent stack's `TemplateURL` properties point into this bucket. GitSync cannot store child templates — only the parent template path is given to GitSync; children must be reachable via HTTPS. Versioning is enabled so CloudFormation can reliably read specific revisions. |
| `TemplatesBucketPolicy` | `AWS::S3::BucketPolicy` | Enforces two rules: (1) denies all non-TLS requests to the bucket, preventing accidental HTTP exposure; (2) explicitly allows `cloudformation.amazonaws.com` to read objects, which is required for CloudFormation to download nested stack templates. |
| `InfraGitHubActionsRole` | `AWS::IAM::Role` | The IAM role that the **infra-repo** GitHub Actions workflow assumes via OIDC. Its trust policy is scoped to `repo:adamsMiracle/infra-repo:*` — any branch or ref in that repo. Its permission policy allows S3 uploads (to push updated child templates) and CloudFormation stack-update actions (to kick the parent stack after a template change). |

---

### 3.2 Network Stack (`01-network.yaml`)

Creates all Layer-3 isolation — the VPC, subnets across two AZs, routing, NAT, and VPC endpoints.

| Resource (logical ID) | AWS Type | Why it exists |
|---|---|---|
| `Vpc` | `AWS::EC2::VPC` | The private network boundary for the entire lab. CIDR `10.20.0.0/16`. DNS hostnames and DNS support are enabled — required for interface VPC endpoints to resolve via private DNS. |
| `InternetGateway` | `AWS::EC2::InternetGateway` | Allows internet-bound traffic from the **public** subnets (used by the ALB). Private subnets route through NAT, not this gateway directly. |
| `AttachGateway` | `AWS::EC2::VPCGatewayAttachment` | Attaches the IGW to the VPC. Required before any public route can reference it. |
| `PublicSubnet1` | `AWS::EC2::Subnet` | AZ-a public subnet (`10.20.0.0/24`). Hosts one of the two ALB network interfaces. `MapPublicIpOnLaunch` is disabled — the ALB does not need per-ENI public IPs; the ALB gets its own DNS. |
| `PublicSubnet2` | `AWS::EC2::Subnet` | AZ-b public subnet (`10.20.1.0/24`). Second ALB network interface for cross-AZ high availability. |
| `PrivateSubnet1` | `AWS::EC2::Subnet` | AZ-a private subnet (`10.20.10.0/24`). ECS Fargate tasks run here. No direct internet access. |
| `PrivateSubnet2` | `AWS::EC2::Subnet` | AZ-b private subnet (`10.20.11.0/24`). Second AZ for ECS Fargate — tasks can run in either AZ for high availability. |
| `PublicRouteTable` | `AWS::EC2::RouteTable` | Route table shared by both public subnets. Contains the `0.0.0.0/0 → IGW` default route. |
| `PublicDefaultRoute` | `AWS::EC2::Route` | The actual default route (`0.0.0.0/0` via `InternetGateway`) in the public route table. |
| `PublicSubnet1Assoc` | `AWS::EC2::SubnetRouteTableAssociation` | Associates `PublicSubnet1` with `PublicRouteTable`. |
| `PublicSubnet2Assoc` | `AWS::EC2::SubnetRouteTableAssociation` | Associates `PublicSubnet2` with `PublicRouteTable`. |
| `PrivateRouteTable` | `AWS::EC2::RouteTable` | Route table shared by both private subnets. Default route points to the NAT Gateway for general internet egress (e.g., pulling public base images on first launch). |
| `PrivateSubnet1Assoc` | `AWS::EC2::SubnetRouteTableAssociation` | Associates `PrivateSubnet1` with `PrivateRouteTable`. |
| `PrivateSubnet2Assoc` | `AWS::EC2::SubnetRouteTableAssociation` | Associates `PrivateSubnet2` with `PrivateRouteTable`. |
| `NatGateway` | `AWS::EC2::NatGateway` | Regional (multi-AZ HA) NAT Gateway — `AvailabilityMode: regional` with `VpcId` instead of a single `SubnetId`, so AWS spreads it across AZs automatically. Enables outbound internet access from private subnets (e.g. pulling the public placeholder image on first launch) without exposing tasks to inbound connections. `ConnectivityType: public`; AWS manages the address allocation, so there is no separately defined Elastic IP resource. |
| `PrivateDefaultRoute` | `AWS::EC2::Route` | The default route (`0.0.0.0/0` via `NatGateway`) in the private route table. |
| `EndpointSecurityGroup` | `AWS::EC2::SecurityGroup` | Permits HTTPS (port 443) from within the VPC CIDR to the interface VPC endpoints. Only inbound traffic from the VPC is allowed; no inbound from the internet. |
| `EcrApiEndpoint` | `AWS::EC2::VPCEndpoint` (Interface) | VPC endpoint for `ecr.api`. ECS Fargate tasks in private subnets call ECR API calls (authenticate, describe images) through this endpoint instead of routing via NAT. Eliminates NAT data-transfer cost for ECR API traffic and keeps ECR API calls inside the AWS network. |
| `EcrDkrEndpoint` | `AWS::EC2::VPCEndpoint` (Interface) | VPC endpoint for `ecr.dkr`. Fargate pulls Docker image layers through this endpoint. Docker layer downloads can be large; routing through VPC endpoint keeps them private and avoids NAT. |
| `LogsEndpoint` | `AWS::EC2::VPCEndpoint` (Interface) | VPC endpoint for `logs` (CloudWatch Logs). ECS task containers ship logs via `awslogs` driver; this endpoint keeps log traffic inside the VPC. |
| `SecretsManagerEndpoint` | `AWS::EC2::VPCEndpoint` (Interface) | VPC endpoint for `secretsmanager`. Future container configurations that need secrets can retrieve them privately without NAT egress. |
| `S3GatewayEndpoint` | `AWS::EC2::VPCEndpoint` (Gateway) | Gateway-type endpoint for S3. Fargate uses S3 when pulling ECR image layers (ECR stores layers in S3). A gateway endpoint has no per-hour cost and routes S3 traffic through the AWS backbone — bypassing NAT entirely. Added to `PrivateRouteTable`. |
| `SsmMessagesEndpoint` | `AWS::EC2::VPCEndpoint` (Interface) | VPC endpoint for `ssmmessages`. Required for ECS Exec (`EnableExecuteCommand: true` on the ECS service), which lets engineers shell into running containers for debugging without opening SSH. |

---

### 3.3 ECR Stack (`02-ecr.yaml`)

Creates the container registry and the OIDC role the **app** repo uses to push images and trigger deployments.

| Resource (logical ID) | AWS Type | Why it exists |
|---|---|---|
| `EcrRepository` | `AWS::ECR::Repository` | The private Docker registry for the application image. Named `ecs-ci-cd-app`. Tag mutability is **`MUTABLE`** so the app workflow can re-push the `latest` tag on every build — the CodePipeline ECR source action tracks `latest`. Per-build immutability is still provided by the unique commit-SHA tag pushed alongside `latest`. `ScanOnPush` is enabled for vulnerability scanning. Lifecycle policy keeps only the last 10 images, preventing unbounded storage growth. |
| `GitHubActionsEcrPushRole` | `AWS::IAM::Role` | OIDC-federated role assumed by the **app-repo** GitHub Actions workflow (`repo:Adamsmiracle/aws_lab_applications:*`). Its permission policy is scoped to **ECR push only** (authenticate + upload layers + `PutImage`). The workflow no longer uploads to S3 or starts the pipeline — EventBridge triggers the pipeline and CodeBuild generates the deploy files — so those permissions were removed. This role replaces long-lived AWS access keys. |

---

### 3.4 ALB + ECS Stack (`03-alb-ecs.yaml`)

Creates the public entry point, all compute resources, IAM task roles, logging, and autoscaling.

| Resource (logical ID) | AWS Type | Why it exists |
|---|---|---|
| `AlbSecurityGroup` | `AWS::EC2::SecurityGroup` | Security group for the ALB. Allows inbound HTTP (port 80) from `0.0.0.0/0`. Egress is restricted to port 80 toward the VPC CIDR only — the ALB cannot initiate traffic to arbitrary destinations. |
| `ServiceSecurityGroup` | `AWS::EC2::SecurityGroup` | Security group for ECS Fargate tasks. Has no inbound rules of its own; inbound is added via a separate ingress rule referencing the ALB SG. Egress allows HTTPS (443) outbound for ECR pulls, CloudWatch Logs, Secrets Manager, and SSM. |
| `ServiceIngressFromAlb` | `AWS::EC2::SecurityGroupIngress` | Adds a rule to `ServiceSecurityGroup` permitting TCP on `ContainerPort` sourced from `AlbSecurityGroup`. Defined as a separate resource (not inline) to avoid the circular reference that would arise if both SGs referenced each other. |
| `LoadBalancer` | `AWS::ElasticLoadBalancingV2::LoadBalancer` | Internet-facing Application Load Balancer. Placed in both public subnets for multi-AZ availability. Drops invalid HTTP headers (`routing.http.drop_invalid_header_fields.enabled: true`) for security. |
| `TargetGroupBlue` | `AWS::ElasticLoadBalancingV2::TargetGroup` | The **blue** target group. Receives live production traffic during normal operation. Health checks hit `GET /` every 15 seconds; 2 consecutive successes mark a target healthy, 3 failures mark it unhealthy. Deregistration delay is 30 seconds to allow in-flight requests to complete. |
| `TargetGroupGreen` | `AWS::ElasticLoadBalancingV2::TargetGroup` | The **green** target group. During a blue/green deployment, the new task version registers here first. CodeDeploy shifts traffic from blue → green once green is healthy. After deployment succeeds, old blue tasks are terminated after 5 minutes. |
| `HttpListener` | `AWS::ElasticLoadBalancingV2::Listener` | The ALB HTTP:80 listener. By default forwards to `TargetGroupBlue`. CodeDeploy modifies this listener's rule to perform the traffic shift during deployments. |
| `TaskExecutionRole` | `AWS::IAM::Role` | IAM role assumed by the **ECS agent** (not the container process). It carries `AmazonECSTaskExecutionRolePolicy`, which allows pulling images from ECR and writing logs to CloudWatch. Required for Fargate to start any task. |
| `TaskRole` | `AWS::IAM::Role` | IAM role assumed by the **container process** at runtime. It grants `ssmmessages:*` actions, enabling ECS Exec (interactive shell into containers). Any application-level AWS calls the container makes would also use this role. |
| `LogGroup` | `AWS::Logs::LogGroup` | CloudWatch Logs group `/ecs/ecs-ci-cd`. Container stdout/stderr streams land here via the `awslogs` log driver. Retention is 14 days to control storage costs. |
| `Cluster` | `AWS::ECS::Cluster` | The ECS cluster `ecs-ci-cd-cluster`. Container Insights is enabled for CloudWatch metrics (CPU, memory, network per task). |
| `TaskDefinition` | `AWS::ECS::TaskDefinition` | Blueprint for a Fargate task: 512 CPU units (0.5 vCPU), 1024 MB memory, Linux/x86_64. Contains one container (`app`) mapped to the container port (`8080` by default, matching the Spring Boot app). The initial image is a public nginx placeholder; CodeDeploy replaces it with the real image on the first deployment. |
| `Service` | `AWS::ECS::Service` | The ECS service `ecs-ci-cd-service`. Keeps 1 running task (desired) in private subnets across AZs. Deployment controller is `CODE_DEPLOY` — this locks CodeDeploy as the exclusive deployment mechanism, preventing CloudFormation and ECS from competing to update the task definition. `EnableExecuteCommand: true` enables ECS Exec. |
| `ScalableTarget` | `AWS::ApplicationAutoScaling::ScalableTarget` | Registers the ECS service's task count as an Auto Scaling dimension, allowing it to scale between 1 (min) and 4 (max) tasks. |
| `CpuScalingPolicy` | `AWS::ApplicationAutoScaling::ScalingPolicy` | Target-tracking policy that adjusts task count to keep average CPU utilization at 60%. Scale-out and scale-in cooldowns are both 60 seconds to avoid thrashing. |

---

### 3.5 Pipeline Stack (`04-pipeline.yaml`)

Creates the deployment automation: the S3 artifact store, IAM roles, and the CodeDeploy/CodePipeline resources that execute blue/green deployments.

| Resource (logical ID) | AWS Type | Why it exists |
|---|---|---|
| `ArtifactBucket` | `AWS::S3::Bucket` | S3 bucket `ecs-ci-cd-pipeline-artifacts-<account>-<region>` that acts as CodePipeline's internal artifact store (passing artifacts between the Source, Build, and Deploy stages). It is managed entirely by the pipeline — nothing is uploaded to it manually. Versioning is enabled; lifecycle rules expire current versions after 30 days and non-current versions after 7 days. |
| `ArtifactBucketPolicy` | `AWS::S3::BucketPolicy` | Denies all non-TLS (`aws:SecureTransport: false`) requests to the artifact bucket. Ensures pipeline artifacts are never transferred unencrypted. |
| `CodeBuildRole` | `AWS::IAM::Role` | IAM role assumed by the CodeBuild project. Least-privilege: write to its own CloudWatch Logs group, and read/write the pipeline artifact bucket objects. |
| `DeployFilesProject` | `AWS::CodeBuild::Project` | CodeBuild project `ecs-ci-cd-deploy-files`. Runs in the **Build** stage and generates the two deployment files at deploy time: `taskdef.json` (built with `jq`, with `<IMAGE1_NAME>` as the image placeholder) and `appspec.yaml`. The task execution/task role ARNs, container name (`app`), port, CPU, and memory are injected as environment variables so the generated task definition always matches the ECS stack. This is why the **app repo never needs to know any infra details**. |
| `CodeDeployRole` | `AWS::IAM::Role` | IAM role assumed by CodeDeploy. Carries `AWSCodeDeployRoleForECS`, which allows CodeDeploy to register task definitions, update ECS services, and manipulate ALB listener rules during a blue/green swap. |
| `CodePipelineRole` | `AWS::IAM::Role` | IAM role assumed by CodePipeline. Permissions are least-privilege: read/write only to `ArtifactBucket`; create-deployment and describe actions on the specific CodeDeploy application and deployment group; ECS describe/update on the specific service; `iam:PassRole` scoped to roles named `ecs-ci-cd-*` passed only to `ecs-tasks.amazonaws.com`; `ecr:DescribeImages` for the ECR source action; and `codebuild:StartBuild`/`BatchGetBuilds`/`StopBuild` on `DeployFilesProject`. |
| `CodeDeployApp` | `AWS::CodeDeploy::Application` | The CodeDeploy application `ecs-ci-cd-cd-app`. The compute platform is `ECS`, which enables blue/green deployment semantics for ECS services. |
| `CodeDeployDeploymentGroup` | `AWS::CodeDeploy::DeploymentGroup` | Wires CodeDeploy to the ECS service and ALB. Deployment type is `BLUE_GREEN` with traffic control. Configuration: on new deploy, start routing traffic to the green environment; if not approved within 60 minutes, stop the deployment. After successful traffic shift, terminate old (blue) tasks after 5 minutes. Auto-rollback is enabled on deployment failure or alarm. Uses `CodeDeployDefault.ECSLinear10PercentEvery1Minutes` — traffic shifts to green in 10% increments every minute. |
| `Pipeline` | `AWS::CodePipeline::Pipeline` | Three-stage pipeline `ecs-ci-cd-pipeline`. **Source** stage: ECR provider tracking the `latest` tag of `ecs-ci-cd-app` — emits an `ImageArtifact` containing the auto-generated `imageDetail.json`. **Build** stage: runs `DeployFilesProject` (CodeBuild) to produce `taskdef.json` + `appspec.yaml` as `DeployArtifact`. **Deploy** stage: invokes `CodeDeployToECS` using `taskdef.json`/`appspec.yaml` from `DeployArtifact` and the image URI from `ImageArtifact` (`Image1ContainerName: IMAGE1_NAME`). |
| `EventBridgePipelineRole` | `AWS::IAM::Role` | IAM role assumed by EventBridge to start the pipeline. Grants only `codepipeline:StartPipelineExecution` on this pipeline. |
| `EcrImagePushRule` | `AWS::Events::Rule` | EventBridge rule matching `source: aws.ecr`, `detail-type: ECR Image Action`, `action-type: PUSH`, `result: SUCCESS`, `repository-name: ecs-ci-cd-app`. On match it calls `StartPipelineExecution` on the pipeline — this is what links an image push to a deployment. |

---

## 4. How Resources Are Linked

### 4.1 Parameter Flow (CloudFormation)

The parent stack acts as a wiring harness — it reads outputs from each child and passes them as parameters to the next child that needs them:

```
Parent
 ├─ NetworkStack
 │    Outputs: VpcId, VpcCidr, PublicSubnet1/2, PrivateSubnet1/2
 │
 ├─ EcrStack
 │    (no network inputs needed)
 │    Outputs: EcrRepositoryUri, GitHubActionsRoleArn
 │
 ├─ AlbEcsStack
 │    Inputs FROM NetworkStack: VpcId, VpcCidr, PublicSubnet1/2, PrivateSubnet1/2
 │    Outputs: ClusterName, ServiceName, TargetGroupBlueName,
 │             TargetGroupGreenName, HttpListenerArn, AlbDnsName
 │
 └─ PipelineStack
      Inputs FROM AlbEcsStack: ClusterName, ServiceName,
                               TargetGroupBlueName, TargetGroupGreenName,
                               HttpListenerArn, TaskExecutionRoleArn, TaskRoleArn
      Inputs FROM EcrStack:    EcrRepositoryName
      (ContainerPort/Cpu/Memory passed from the parent — injected into CodeBuild
       so the generated taskdef.json matches the ECS task definition)
```

### 4.2 Runtime Connections

| From | To | Connection |
|---|---|---|
| Internet / Users | `LoadBalancer` (public subnets) | HTTP:80 inbound |
| `LoadBalancer` | ECS tasks (private subnets) | HTTP:80 via `TargetGroupBlue` or `TargetGroupGreen` |
| ECS tasks | `EcrDkrEndpoint` + `EcrApiEndpoint` | Docker image pull (HTTPS:443, stays in VPC) |
| ECS tasks | `S3GatewayEndpoint` | ECR image layer download from S3 (HTTPS, free gateway endpoint) |
| ECS tasks | `LogsEndpoint` | Container log delivery to CloudWatch (HTTPS:443) |
| ECS tasks | `SecretsManagerEndpoint` | Secret retrieval (HTTPS:443, if used) |
| ECS tasks | `SsmMessagesEndpoint` | ECS Exec / interactive sessions (HTTPS:443) |
| GitHub Actions (app-repo) | `EcrRepository` via `GitHubActionsEcrPushRole` | Docker push of `<sha>` + `latest` (OIDC → STS → ECR) |
| `EcrRepository` (image push event) | `EcrImagePushRule` → `Pipeline` | EventBridge rule calls `StartPipelineExecution` |
| `Pipeline` (Source) | `EcrRepository` | ECR source action reads the `latest` image → `imageDetail.json` |
| `Pipeline` (Build) | `DeployFilesProject` | CodeBuild generates `taskdef.json` + `appspec.yaml` |
| `Pipeline` (Deploy) | `CodeDeployDeploymentGroup` | Invokes `CodeDeployToECS` with the generated files + image URI |
| `CodeDeployDeploymentGroup` | `LoadBalancer` (`HttpListenerArn`) | Manipulates listener rules during traffic shift |
| `CodeDeployDeploymentGroup` | `Service` | Updates ECS service to the new task definition |
| GitHub Actions (infra-repo) | `TemplatesBucket` via `InfraGitHubActionsRole` | Upload child `.yaml` templates |
| CloudFormation GitSync | `parent.yaml` (in infra-repo) | Watches `deployment.yaml`; triggers stack update on change |
| CloudFormation (parent) | `TemplatesBucket` | Downloads child template URLs for nested stacks |

---

## 5. End-to-End Workflows

### 5.1 Infrastructure Update Workflow

```
Developer pushes to infra-repo (ecs-ci-cd branch)
    │
    ▼
GitHub Actions: sync-infra-templates.yml
    ├─ 1. Configure AWS credentials via OIDC
    │       (assumes InfraGitHubActionsRole from bootstrap stack)
    │
    ├─ 2. Diff against HEAD~1 — find changed template files
    │
    ├─ 3. Upload each changed file to S3 TemplatesBucket
    │       (e.g., children/03-alb-ecs.yaml → s3://ecs-ci-cd-cfn-templates-…/children/03-alb-ecs.yaml)
    │
    ├─ 4. Bump TemplateVersion in deployment.yaml
    │       (sha-<short-commit>) — this is a cache-buster
    │
    └─ 5. Commit and push the TemplateVersion bump
            │
            ▼
        CloudFormation GitSync detects change in deployment.yaml
            │
            ▼
        Parent stack update triggered
            │
            ├─ TemplateVersion parameter propagated to all child stacks
            ├─ CloudFormation downloads updated child templates from S3
            └─ Affected child stacks are updated (changed resources replaced/updated)
```

### 5.2 Application Build & Image Push Workflow

```
Developer pushes to app-repo (aws_lab_applications, branch ecs-ci-cd)
    │
    ▼
GitHub Actions: build-and-push workflow (in app-repo)
    ├─ 1. Configure AWS credentials via OIDC
    │       (assumes GitHubActionsEcrPushRole from ECR stack)
    │
    ├─ 2. Authenticate to ECR (ecr:GetAuthorizationToken)
    │
    ├─ 3. Build Docker image from application source
    │
    ├─ 4. Tag image twice:
    │       ├─ ecs-ci-cd-app:<sha>     (unique, immutable per-build reference)
    │       └─ ecs-ci-cd-app:latest    (pointer the pipeline ECR source tracks)
    │
    └─ 5. Push both tags to EcrRepository
            (pushing `latest` is what fires the EventBridge rule)

The workflow stops here. It produces no deploy bundle and does not call
StartPipelineExecution — the infra owns everything downstream.
```

### 5.3 Blue/Green Deployment Workflow

```
ECR image push (latest) ──► EcrImagePushRule (EventBridge)
    │
    └─ StartPipelineExecution
        │
        ▼
CodePipeline — Source Stage (ECR provider)
    └─ Reads the `latest` image from ecs-ci-cd-app
        → emits ImageArtifact (contains imageDetail.json with the image URI)
        │
        ▼
CodePipeline — Build Stage (CodeBuild: DeployFilesProject)
    └─ Generates taskdef.json (image = <IMAGE1_NAME>) + appspec.yaml
        → emits DeployArtifact
        │
        ▼
CodePipeline — Deploy Stage (CodeDeployToECS provider)
    └─ Creates a CodeDeploy deployment
       (taskdef.json/appspec.yaml from DeployArtifact;
        <IMAGE1_NAME> replaced by the URI from ImageArtifact)
            │
            ▼
        CodeDeploy — Blue/Green Deployment
            │
            ├─ 1. Register new task definition (new image URI from taskdef.json)
            │
            ├─ 2. Start NEW tasks using new task definition
            │       → Tasks register to TargetGroupGreen
            │
            ├─ 3. Wait for Green tasks to pass ALB health checks
            │       (2 consecutive HTTP 200 on GET /)
            │
            ├─ 4. Shift ALB traffic:
            │       HttpListener default action → TargetGroupGreen (100%)
            │
            ├─ 5. Wait 5 minutes (TerminationWaitTimeInMinutes)
            │
            └─ 6. Terminate old (Blue) tasks
                    └─ Deregistration delay: 30 seconds to drain connections

        If deployment fails at any step:
            └─ Auto-rollback: revert listener to TargetGroupBlue, terminate Green tasks
```

---

## 6. Architecture Diagram

```
┌─────────────────────────────── GitHub ──────────────────────────────┐
│                                                                      │
│  infra-repo (ecs-ci-cd branch)    app-repo                          │
│  sync-infra-templates.yml         build-and-push.yml                │
│         │  OIDC                           │  OIDC                   │
└─────────┼───────────────────────────────┼─────────────────────────┘
          │                               │
          ▼                               ▼
   InfraGitHubActionsRole          GitHubActionsEcrPushRole
          │                               │
          │ S3 upload                     │ docker push
          ▼                               ▼
   TemplatesBucket ───────────►   EcrRepository (ECR)
   (child templates)                      │
          │                               │
   CloudFormation                         │ ECR push event (latest tag)
   GitSync reads                          ▼
   deployment.yaml             EcrImagePushRule (EventBridge)
          │                               │ StartPipelineExecution
          ▼                               ▼
   Parent Stack Update         ┌─────────────────────────────────────────┐
   (nested stacks)             │ CodePipeline                              │
                               │  Source: ECR latest → imageDetail.json    │
                               │     ▼                                     │
                               │  Build:  CodeBuild → taskdef + appspec    │
                               │     ▼                                     │
                               │  Deploy: CodeDeploy (Blue/Green ECS)      │
                               └─────────────────────────────────────────┘
                  │
                  ▼
┌───────────────── VPC (10.20.0.0/16) ────────────────────────────────┐
│                                                                      │
│  ┌─── AZ-a ────────────────┐  ┌─── AZ-b ────────────────────────┐  │
│  │ PublicSubnet1            │  │ PublicSubnet2                    │  │
│  │ 10.20.0.0/24             │  │ 10.20.1.0/24                    │  │
│  │  ┌──────────────────┐   │  │  ┌──────────────────────────┐   │  │
│  │  │  ALB ENI         │   │  │  │  ALB ENI                 │   │  │
│  │  └──────────────────┘   │  │  └──────────────────────────┘   │  │
│  │  (regional NAT Gateway spans both AZs — AWS-managed address)    │  │
│  └──────────────────────────┘  └─────────────────────────────────┘  │
│           │  (routes via IGW → internet users)                       │
│           │                                                          │
│  ┌─── AZ-a ────────────────┐  ┌─── AZ-b ────────────────────────┐  │
│  │ PrivateSubnet1           │  │ PrivateSubnet2                  │  │
│  │ 10.20.10.0/24            │  │ 10.20.11.0/24                  │  │
│  │  ┌──────────────────┐   │  │  ┌──────────────────────────┐   │  │
│  │  │  ECS Task (Blue) │   │  │  │  ECS Task (Green)        │   │  │
│  │  └──────────────────┘   │  │  └──────────────────────────┘   │  │
│  └──────────────────────────┘  └─────────────────────────────────┘  │
│                                                                      │
│  VPC Endpoints (private subnets):                                    │
│  ├─ ecr.api   (Interface) ─── ECS → ECR API                         │
│  ├─ ecr.dkr   (Interface) ─── ECS → Docker layer pull               │
│  ├─ s3        (Gateway)   ─── ECS → ECR S3 layer storage            │
│  ├─ logs      (Interface) ─── ECS → CloudWatch Logs                 │
│  ├─ secretsmanager (Interface)                                       │
│  └─ ssmmessages    (Interface) ─── ECS Exec / debug shell           │
└──────────────────────────────────────────────────────────────────────┘

Internet users ──► ALB (public DNS) ──► TargetGroupBlue/Green ──► ECS Tasks
                                                                       │
                                             CloudWatch Logs ◄─────────┘
```

---

## 7. Security Design

| Control | Implementation | Why |
|---|---|---|
| **No long-lived secrets** | All GitHub Actions use `AssumeRoleWithWebIdentity` (OIDC). No AWS access keys stored in GitHub. | Eliminates the primary credential-leak risk in CI/CD pipelines. |
| **OIDC scope pinned to repo** | `token.actions.githubusercontent.com:sub: repo:<org>/<repo>:*` condition on all OIDC roles. | Prevents other repos in the same org from assuming these roles. |
| **ECS tasks in private subnets** | `AssignPublicIp: DISABLED`. Tasks have no public IPs. | Tasks are unreachable from the internet. The only inbound path is through the ALB. |
| **ALB is the sole public entry point** | `AlbSecurityGroup` allows HTTP:80 from the internet. `ServiceSecurityGroup` allows inbound only from `AlbSecurityGroup`. | Defense in depth — no direct path to containers. |
| **Per-build immutable references** | Every image is tagged with its commit SHA (`ecs-ci-cd-app:<sha>`) in addition to `latest`. | The SHA tag is a permanent, unambiguous reference to exactly what was built, even though `latest` is mutable (mutable is required so the pipeline's ECR source can track a stable tag). |
| **Image scanning on push** | `ScanOnPush: true` on ECR. | CVEs are surfaced immediately after build. |
| **VPC endpoints for AWS services** | Interface endpoints for ECR, Logs, Secrets Manager, SSM; Gateway endpoint for S3. | ECR pulls, log shipping, and secret access never traverse the public internet or the NAT. |
| **S3 buckets deny HTTP** | `DenyInsecureTransport` bucket policy on both `TemplatesBucket` and `ArtifactBucket`. | Templates and deploy artifacts cannot be read over unencrypted HTTP. |
| **S3 buckets block all public access** | `PublicAccessBlockConfiguration` fully enabled on both buckets. | Prevents accidental public exposure of CFN templates or deploy artifacts. |
| **ALB drops invalid headers** | `routing.http.drop_invalid_header_fields.enabled: true`. | Prevents HTTP header injection attacks reaching the containers. |
| **Blue/green auto-rollback** | `AutoRollbackConfiguration` on `DEPLOYMENT_FAILURE` and `DEPLOYMENT_STOP_ON_ALARM`. | A bad deployment automatically reverts; production traffic stays on the healthy blue environment. |
| **Event-driven pipeline trigger** | `EcrImagePushRule` (EventBridge) starts the pipeline via `codepipeline:StartPipelineExecution` only on a successful ECR image push. | No polling and no broad app-repo permissions; the deployment is driven by the registry event itself, and the app role is scoped to ECR push only. |
| **Deploy files generated in infra** | CodeBuild (`DeployFilesProject`) generates `taskdef.json`/`appspec.yaml` at deploy time from infra-controlled env vars. | The app repo never holds task/execution role ARNs, log group names, or sizing — infra details stay in the infra repo. |
| **ECS Exec enabled** | `EnableExecuteCommand: true` + `SsmMessagesEndpoint` + `TaskRole` SSM permissions. | Engineers can open an interactive shell into containers for debugging via SSM (no SSH, no bastion needed). |
| **Least-privilege IAM** | Each role (CodePipeline, CodeDeploy, TaskExecution, Task, InfraGHA, AppGHA) has only the permissions its principal actually needs, scoped to specific resource ARNs where possible. | Limits blast radius if any credential or service is compromised. |
