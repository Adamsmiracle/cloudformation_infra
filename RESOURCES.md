# Resource Reference — ECS CI/CD Lab

Two views of every resource in the stack:

1. **[Part A — High-level functionality table](#part-a--high-level-functionality)** — what each resource is for.
2. **[Part B — Line-by-line explanation](#part-b--line-by-line-explanation)** — every meaningful property explained, with **alternate values** you could set.

Stacks, in deploy order: `00-bootstrap` → (GitSync) → `parent` → `01-network` → `02-ecr` → `03-alb-ecs` → `04-pipeline`.

---

## Part A — High-level functionality

### Bootstrap stack (`00-bootstrap.yaml`) — deployed once, manually
| Resource | Type | Function |
|---|---|---|
| `TemplatesBucket` | S3 Bucket | Stores the child CloudFormation templates that the parent stack references by URL |
| `TemplatesBucketPolicy` | S3 BucketPolicy | Denies non-TLS access; lets CloudFormation read templates for nested stacks |
| `InfraGitHubActionsRole` | IAM Role | OIDC role the **infra** repo's workflow assumes to upload templates + trigger stack updates |

### Network stack (`01-network.yaml`)
| Resource | Type | Function |
|---|---|---|
| `Vpc` | EC2 VPC | The private network boundary (`10.20.0.0/16`) |
| `InternetGateway` / `AttachGateway` | IGW + attachment | Internet access for the public subnets |
| `PublicSubnet1/2` | EC2 Subnet | Two AZs; host the ALB's network interfaces |
| `PrivateSubnet1/2` | EC2 Subnet | Two AZs; host the ECS Fargate tasks (no public IPs) |
| `PublicRouteTable` + `PublicDefaultRoute` + assocs | Route table/route | Public subnets route `0.0.0.0/0` → IGW |
| `PrivateRouteTable` + `PrivateDefaultRoute` + assocs | Route table/route | Private subnets route `0.0.0.0/0` → NAT |
| `NatGateway` | EC2 NatGateway | Outbound internet for private subnets (regional/HA) |
| `EndpointSecurityGroup` | EC2 SG | Allows HTTPS (443) from the VPC to the interface endpoints |
| `EcrApiEndpoint` | VPC Endpoint (Interface) | ECS → ECR API calls, privately |
| `EcrDkrEndpoint` | VPC Endpoint (Interface) | ECS → Docker image layer pulls, privately |
| `S3GatewayEndpoint` | VPC Endpoint (Gateway) | ECS → S3 (ECR stores layers in S3); free, no NAT |
| `LogsEndpoint` | VPC Endpoint (Interface) | ECS → CloudWatch Logs, privately |
| `SecretsManagerEndpoint` | VPC Endpoint (Interface) | ECS → Secrets Manager, privately (future use) |
| `SsmMessagesEndpoint` | VPC Endpoint (Interface) | ECS Exec interactive shell into containers |

### ECR stack (`02-ecr.yaml`)
| Resource | Type | Function |
|---|---|---|
| `EcrRepository` | ECR Repository | Private Docker registry for the app image (`ecs-ci-cd-app`) |
| `GitHubActionsEcrPushRole` | IAM Role | OIDC role the **app** repo's workflow assumes to push images |

### ALB + ECS stack (`03-alb-ecs.yaml`)
| Resource | Type | Function |
|---|---|---|
| `AlbSecurityGroup` | EC2 SG | ALB: inbound HTTP 80 from internet, egress to tasks |
| `ServiceSecurityGroup` | EC2 SG | Tasks: egress 443; inbound added separately |
| `ServiceIngressFromAlb` | SG Ingress | Allows tasks to receive traffic **only** from the ALB SG |
| `LoadBalancer` | ALB | Public entry point across both public subnets |
| `TargetGroupBlue` | Target Group | Live (blue) task set during normal operation |
| `TargetGroupGreen` | Target Group | New (green) task set during a blue/green deploy |
| `HttpListener` | ALB Listener | HTTP:80, forwards to blue by default |
| `TaskExecutionRole` | IAM Role | Lets the ECS agent pull images + write logs |
| `TaskRole` | IAM Role | Permissions for the running container (ECS Exec) |
| `LogGroup` | CloudWatch Logs | Container stdout/stderr (`/ecs/ecs-ci-cd`) |
| `Cluster` | ECS Cluster | Logical group for the service/tasks |
| `TaskDefinition` | ECS Task Def | Blueprint: image, CPU/memory, port, logging |
| `Service` | ECS Service | Keeps tasks running; wired to CodeDeploy + ALB |
| `ScalableTarget` | App Auto Scaling | Registers task count as scalable (1–4) |
| `CpuScalingPolicy` | Scaling Policy | Target-tracking on average CPU |

### Pipeline stack (`04-pipeline.yaml`)
| Resource | Type | Function |
|---|---|---|
| `ArtifactBucket` | S3 Bucket | CodePipeline's internal artifact store |
| `ArtifactBucketPolicy` | S3 BucketPolicy | Denies non-TLS access to artifacts |
| `CodeBuildRole` | IAM Role | Permissions for the CodeBuild project |
| `DeployFilesProject` | CodeBuild Project | Generates `taskdef.json` + `appspec.yaml` at deploy time |
| `CodeDeployRole` | IAM Role | Lets CodeDeploy drive the ECS blue/green swap |
| `CodePipelineRole` | IAM Role | Lets CodePipeline orchestrate the stages |
| `CodeDeployApp` | CodeDeploy Application | Container for the deployment group (ECS platform) |
| `CodeDeployDeploymentGroup` | Deployment Group | Defines the blue/green swap behavior + rollback |
| `EventBridgePipelineRole` | IAM Role | Lets EventBridge start the pipeline |
| `EcrImagePushRule` | EventBridge Rule | Starts the pipeline on a `latest` image push |
| `Pipeline` | CodePipeline | 3 stages: ECR Source → CodeBuild → CodeDeploy |

### Parent + deployment file
| File/Resource | Function |
|---|---|
| `parent.yaml` | Instantiates the 4 nested stacks; passes parameters down, wires outputs across |
| `deployment.yaml` | The GitSync deployment file: parameter values + which template GitSync watches |

---

## Part B — Line-by-line explanation

> Convention below: **▸ Alternatives:** lists other values that property accepts and what they'd do.

---

### `00-bootstrap.yaml`

```yaml
ProjectName: { Default: ecs-ci-cd }          # name prefix for every resource
GitHubOrg:   { Default: Adamsmiracle }        # GitHub owner of the infra repo
InfraRepoName: { Default: cloudformation_infra }
AppRepoName:   { Default: aws_lab_applications }
```
- `ProjectName` — prefixes bucket/role names. ▸ Alternatives: any DNS-safe string (`my-ecs-lab`).
- `GitHubOrg` / `InfraRepoName` — used in the OIDC trust `sub`. ▸ Must exactly match your real GitHub `owner/repo`.

```yaml
TemplatesBucket:
  DeletionPolicy: Retain          # keep bucket if stack deleted
  UpdateReplacePolicy: Retain
  BucketName: !Sub "${ProjectName}-cfn-templates-${AWS::AccountId}-${AWS::Region}"
  VersioningConfiguration: { Status: Enabled }
  PublicAccessBlockConfiguration: { all four: true }
  BucketEncryption: AES256, BucketKeyEnabled: true
  LifecycleConfiguration: NoncurrentVersionExpirationInDays: 30
```
- `DeletionPolicy: Retain` — bucket survives stack deletion. ▸ Alternatives: `Delete` (remove with stack), `Snapshot` (n/a for S3).
- `VersioningConfiguration: Enabled` — keeps old template revisions. ▸ Alternatives: `Suspended`.
- `SSEAlgorithm: AES256` — S3-managed encryption. ▸ Alternatives: `aws:kms` (+ `KMSMasterKeyID`) for CMK control.
- `NoncurrentVersionExpirationInDays: 30` — purge old versions after 30 d. ▸ Alternatives: any integer; lower = cheaper, less history.

```yaml
InfraGitHubActionsRole:
  RoleName: !Sub "${ProjectName}-infra-gha-role"
  ...Federated: ...oidc-provider/token.actions.githubusercontent.com
  ...sub: !Sub "repo:${GitHubOrg}/${InfraRepoName}:*"
```
- `sub: repo:.../...:*` — trusts **any branch/ref** of the infra repo. ▸ Alternatives: `:ref:refs/heads/main` (only `main`), `:environment:prod` (only a GH environment) — tighter security.
- Permissions: `s3:PutObject/...` on the bucket + `cloudformation:UpdateStack/CreateChangeSet/...`. ▸ You can narrow CFN actions to just `Describe*` if GitSync (not the workflow) performs the update.

---

### `01-network.yaml`

```yaml
Vpc:
  CidrBlock: !Ref VpcCidr            # 10.20.0.0/16
  EnableDnsHostnames: true
  EnableDnsSupport: true
```
- `CidrBlock` — VPC address space. ▸ Alternatives: any private range, e.g. `10.0.0.0/16`, `172.16.0.0/16`, `192.168.0.0/16`. `/16` = 65k IPs; `/20` is plenty for a lab.
- `EnableDnsHostnames/Support: true` — **required** for interface-endpoint private DNS. ▸ Leave true.

```yaml
PublicSubnet1:
  CidrBlock: !Ref PublicSubnet1Cidr  # 10.20.0.0/24
  AvailabilityZone: !Select [0, !GetAZs '']
  MapPublicIpOnLaunch: false
```
- `AvailabilityZone: !Select [0/1, !GetAZs '']` — picks the 1st/2nd AZ in the region automatically. ▸ Alternatives: hard-code `eu-central-1a`; or add a 3rd subnet with `!Select [2, ...]` for 3-AZ HA.
- `MapPublicIpOnLaunch: false` — instances get no auto public IP. ▸ Alternatives: `true` (needed only if you launch EC2 directly in public subnets; the ALB doesn't need it).
- Subnet CIDRs (`/24` = 251 usable IPs each). ▸ Alternatives: `/26`, `/27` if you want smaller blocks.

```yaml
NatGateway:
  ConnectivityType: public
  AvailabilityMode: regional
```
- `ConnectivityType: public` — NAT has a public IP for internet egress. ▸ Alternatives: `private` (no internet, only VPC-to-VPC).
- `AvailabilityMode: regional` — AWS spreads NAT across AZs (HA). ▸ Alternatives: omit + use `SubnetId` for a single-AZ NAT (cheaper, less resilient). **Cost note:** a NAT gateway is the most expensive piece here; for a pure-VPC-endpoint setup you could remove NAT entirely if tasks never need general internet.

```yaml
EndpointSecurityGroup:
  Ingress: tcp 443 from VpcCidr
  Egress:  tcp 443 to VpcCidr
```
- 443 from/to the VPC CIDR — only in-VPC HTTPS reaches the endpoints. ▸ Alternatives: tighten `CidrIp` to just the private-subnet CIDRs instead of the whole VPC.

```yaml
EcrApiEndpoint / EcrDkrEndpoint / LogsEndpoint / SecretsManagerEndpoint / SsmMessagesEndpoint:
  VpcEndpointType: Interface
  PrivateDnsEnabled: true
  SubnetIds: [PrivateSubnet1, PrivateSubnet2]

S3GatewayEndpoint:
  VpcEndpointType: Gateway
  RouteTableIds: [PrivateRouteTable]
```
- `VpcEndpointType: Interface` — ENI-based, ~$/hr each + data. ▸ Alternatives: `Gateway` only exists for S3/DynamoDB (free).
- `PrivateDnsEnabled: true` — lets normal AWS SDK URLs resolve to the endpoint. ▸ Alternatives: `false` (you'd use the endpoint-specific DNS name manually — rarely wanted).
- The 5 interface endpoints are the minimum for Fargate-in-private + Exec. ▸ You can drop `SecretsManagerEndpoint` if you never read secrets, or add `ecr`/`sts`/`elasticloadbalancing` endpoints for other needs.

---

### `02-ecr.yaml`

```yaml
EcrRepository:
  DeletionPolicy: Delete
  UpdateReplacePolicy: Retain
  RepositoryName: !Sub "${ProjectName}-app"
  ImageTagMutability: MUTABLE
  ImageScanningConfiguration: { ScanOnPush: true }
  EncryptionConfiguration: { EncryptionType: AES256 }
  LifecyclePolicy: keep last 10 images
```
- `ImageTagMutability: MUTABLE` — `latest` can be overwritten (needed so the pipeline's ECR source tracks `latest`). ▸ Alternatives: `IMMUTABLE` (tags can't be reused — then the pipeline must source by digest or you tag uniquely each time).
- `ScanOnPush: true` — CVE scan on every push. ▸ Alternatives: `false` (no scan); or enhanced scanning via registry settings.
- `EncryptionType: AES256`. ▸ Alternatives: `KMS` (+ `KmsKey`).
- `countNumber: 10` (lifecycle) — keep last 10 images. ▸ Alternatives: any integer; lower = cheaper.

```yaml
GitHubActionsEcrPushRole:
  RoleName: github-actions-ecr-push-role
  ...sub: !Sub "repo:${GitHubOrg}/${AppRepoName}:*"
  EcrPushPolicy: GetAuthorizationToken + BatchCheckLayerAvailability/InitiateLayerUpload/UploadLayerPart/CompleteLayerUpload/PutImage
```
- `sub: repo:.../aws_lab_applications:*` — trusts any ref of the app repo. ▸ Alternatives: pin to `:ref:refs/heads/ecs-ci-cd` to only allow that branch to push.
- Policy is **ECR-push-only** (least privilege). ▸ Add `ecr:BatchGetImage`/`GetDownloadUrlForLayer` only if the workflow also needs to *pull*.

---

### `03-alb-ecs.yaml`

```yaml
AlbSecurityGroup:
  Ingress: tcp 80 from 0.0.0.0/0
  Egress:  tcp <ContainerPort> to VpcCidr
```
- Ingress `80 from 0.0.0.0/0` — public HTTP. ▸ Alternatives: add `443` + an HTTPS listener + ACM cert for TLS; restrict `CidrIp` to an office range for a private lab.

```yaml
ServiceSecurityGroup:
  Egress: tcp 443 to 0.0.0.0/0
ServiceIngressFromAlb:
  tcp <ContainerPort> from AlbSecurityGroup
```
- Tasks accept traffic **only from the ALB SG** (`SourceSecurityGroupId`), not a CIDR — the secure pattern. ▸ Alternatives: none recommended; keep SG-to-SG.
- Egress `443 to 0.0.0.0/0` — outbound HTTPS (endpoints/NAT). ▸ Alternatives: restrict to `VpcCidr` since endpoints are in-VPC.

```yaml
LoadBalancer:
  Scheme: internet-facing
  Type: application
  LoadBalancerAttributes:
    - drop_invalid_header_fields.enabled: 'true'
    - idle_timeout.timeout_seconds: '60'
```
- `Scheme: internet-facing`. ▸ Alternatives: `internal` (private ALB, no public IPs).
- `Type: application`. ▸ Alternatives: `network` (NLB, L4) — but blue/green + path routing want ALB.
- `idle_timeout: 60`. ▸ Alternatives: up to `4000` s for long-poll/streaming apps.

```yaml
TargetGroupBlue / TargetGroupGreen:
  Port: 80                # cosmetic for ip targets; ECS overrides to ContainerPort
  Protocol: HTTP
  TargetType: ip
  HealthCheckPath: /
  HealthCheckIntervalSeconds: 15
  HealthyThresholdCount: 2
  UnhealthyThresholdCount: 3
  Matcher: { HttpCode: 200 }
  deregistration_delay.timeout_seconds: '30'
```
- `TargetType: ip` — required for Fargate/awsvpc. ▸ Alternatives: `instance` (EC2 launch type), `lambda`.
- `HealthCheckPath: /` — health probe URL. ▸ Alternatives: a dedicated `/health` endpoint (cheaper than rendering the page); the reference app uses `/health`.
- `HealthCheckIntervalSeconds: 15` / thresholds `2`/`3`. ▸ Alternatives: lower interval (e.g. `10`) + threshold `2` = faster green-healthy detection = faster deploys; higher = less probe traffic.
- `Matcher 200`. ▸ Alternatives: `200-299`, or `200,302`.
- `deregistration_delay: 30` — drain time before killing a target. ▸ Alternatives: `0` (instant, may drop in-flight requests), up to `3600`.

```yaml
HttpListener:
  Port: 80
  Protocol: HTTP
  DefaultActions: forward → TargetGroupBlue
```
- ▸ Alternatives: add a second `Listener` on `443`/`HTTPS` with `Certificates: [ACM ARN]` for TLS; add a `TestListener` on `8080` (the reference does this) to give CodeDeploy a separate test-traffic route.

```yaml
TaskExecutionRole: managed AmazonECSTaskExecutionRolePolicy
TaskRole: inline ssmmessages:* (ECS Exec)
```
- `TaskExecutionRole` pulls images + writes logs (used by the agent). ▸ Add `secretsmanager:GetSecretValue` here if the container reads secrets at startup.
- `TaskRole` = the app's own AWS identity. ▸ Add app permissions here (e.g. `dynamodb:*`, `s3:*`) as the code needs them.

```yaml
LogGroup:
  LogGroupName: !Sub "/ecs/${ProjectName}"
  RetentionInDays: 14
```
- `RetentionInDays: 14`. ▸ Alternatives: `1,3,7,30,90,365,...` or omit for never-expire (costs more).

```yaml
Cluster:
  ClusterSettings: [{ containerInsights: enabled }]
```
- `containerInsights: enabled` — per-task CPU/mem/network metrics. ▸ Alternatives: `disabled` (cheaper, less visibility).

```yaml
TaskDefinition:
  Cpu: !Ref ContainerCpu        # 512
  Memory: !Ref ContainerMemory  # 1024
  NetworkMode: awsvpc
  RequiresCompatibilities: [FARGATE]
  RuntimePlatform: { LINUX, X86_64 }
  ContainerDefinitions:
    - Name: app
      Image: !Ref InitialImage
      PortMappings: [{ ContainerPort: 8080, Protocol: tcp }]
      Essential: true
      LogConfiguration: awslogs → LogGroup
```
- `Cpu: 512` / `Memory: 1024` — 0.5 vCPU / 1 GB. ▸ **Valid Fargate pairs:** 256→(512/1024/2048), 512→(1024–4096), 1024→(2048–8192), 2048→(4096–16384), 4096→(8192–30720). Memory in MiB.
- `NetworkMode: awsvpc` — mandatory for Fargate. ▸ No alternative on Fargate.
- `CpuArchitecture: X86_64`. ▸ Alternatives: `ARM64` (Graviton — cheaper, needs an ARM image build).
- `Name: app` — **must match** the `ContainerName` in `appspec.yaml` and the `LoadBalancers` block.
- `Image: InitialImage` — placeholder nginx; CodeDeploy replaces it at deploy time.

```yaml
Service:
  DesiredCount: !Ref DesiredCount      # 1
  LaunchType: FARGATE
  PlatformVersion: LATEST
  DeploymentController: { Type: CODE_DEPLOY }
  DeploymentConfiguration: { MinimumHealthyPercent: 100, MaximumPercent: 200 }
  EnableExecuteCommand: true
  NetworkConfiguration: AssignPublicIp: DISABLED, private subnets, ServiceSecurityGroup
  LoadBalancers: container app:8080 → TargetGroupBlue
  HealthCheckGracePeriodSeconds: 60
```
- `DeploymentController: CODE_DEPLOY` — hands deploys to CodeDeploy (blue/green). ▸ Alternatives: `ECS` (rolling, native), `EXTERNAL`.
- `AssignPublicIp: DISABLED` — tasks have no public IP (private subnets). ▸ Alternatives: `ENABLED` only if in public subnets without endpoints/NAT.
- `EnableExecuteCommand: true` — ECS Exec shell. ▸ Alternatives: `false` to disable.
- `HealthCheckGracePeriodSeconds: 60` — ignore health checks for 60 s on start. ▸ Alternatives: raise for slow-booting apps (Spring Boot cold start can want 90–120).
- `MinimumHealthyPercent/MaximumPercent` 100/200 — standard for blue/green.

```yaml
ScalableTarget: { MinCapacity: 1, MaxCapacity: 4, ScalableDimension: ecs:service:DesiredCount }
CpuScalingPolicy:
  PolicyType: TargetTrackingScaling
  PredefinedMetricType: ECSServiceAverageCPUUtilization
  TargetValue: 60
  ScaleInCooldown: 60
  ScaleOutCooldown: 60
```
- `Min 1 / Max 4` — autoscaling bounds (lab requirement). ▸ Alternatives: any ints; raise Max for more headroom.
- `PredefinedMetricType`. ▸ Alternatives: `ECSServiceAverageMemoryUtilization`, or `ALBRequestCountPerTarget` (+ `ResourceLabel`) to scale on request rate.
- `TargetValue: 60` (% CPU). ▸ Alternatives: lower (e.g. 40) = scales out sooner; higher (e.g. 80) = more packed/cheaper.
- Cooldowns `60`. ▸ Alternatives: longer to damp flapping.

---

### `04-pipeline.yaml`

```yaml
ArtifactBucket: versioned, public-access-blocked, AES256, ExpirationInDays: 30
ArtifactBucketPolicy: DenyInsecureTransport
```
- `ExpirationInDays: 30` / `NoncurrentVersionExpirationInDays: 7`. ▸ Alternatives: shorter to save storage.

```yaml
CodeDeployDeploymentGroup:
  DeploymentStyle: { BLUE_GREEN, WITH_TRAFFIC_CONTROL }
  BlueGreenDeploymentConfiguration:
    DeploymentReadyOption: { ActionOnTimeout: CONTINUE_DEPLOYMENT }
    TerminateBlueInstancesOnDeploymentSuccess: { TERMINATE, TerminationWaitTimeInMinutes: 5 }
  AutoRollbackConfiguration: { DEPLOYMENT_FAILURE, DEPLOYMENT_STOP_ON_ALARM }
  DeploymentConfigName: CodeDeployDefault.ECSLinear10PercentEvery1Minutes
```
- `DeploymentType: BLUE_GREEN`. ▸ Alternatives: `IN_PLACE` (not valid for ECS; ECS = blue/green only via CodeDeploy).
- `ActionOnTimeout: CONTINUE_DEPLOYMENT` — auto-shift traffic, no manual approval. ▸ Alternatives: `STOP_DEPLOYMENT` (+ `WaitTimeInMinutes`) = wait for a human to click "Reroute traffic".
- `TerminationWaitTimeInMinutes: 5` — keep old (blue) tasks 5 min for fast rollback. ▸ Alternatives: `0`–`2880`; lower = faster deploy, smaller rollback window.
- `DeploymentConfigName` — **traffic-shift speed** (this is the big deploy-time lever):
  - `ECSAllAtOnce` — 100% instantly (fastest)
  - `ECSCanary10Percent5Minutes` — 10%, wait 5 min, then 90%
  - `ECSCanary10Percent15Minutes`
  - `ECSLinear10PercentEvery1Minutes` ← *current* (~9–10 min)
  - `ECSLinear10PercentEvery3Minutes` (~30 min)

```yaml
EcrImagePushRule:
  EventPattern: source aws.ecr / detail-type "ECR Image Action" / action-type PUSH / result SUCCESS / repository-name ecs-ci-cd-app / image-tag latest
  Targets: → Pipeline (RoleArn EventBridgePipelineRole)
```
- `image-tag: [latest]` — only a `latest` push triggers (avoids the double-fire from the `<sha>` push). ▸ Alternatives: remove it to fire on any tag; or list specific tags.

```yaml
DeployFilesProject (CodeBuild):
  Image: aws/codebuild/standard:7.0
  ComputeType: BUILD_GENERAL1_SMALL
  Env: PROJECT_NAME, EXECUTION_ROLE_ARN, TASK_ROLE_ARN, CONTAINER_NAME=app, CONTAINER_PORT/CPU/MEMORY
  BuildSpec: jq → taskdef.json (image=<IMAGE1_NAME>) ; heredoc → appspec.yaml
```
- `ComputeType: BUILD_GENERAL1_SMALL` — smallest/cheapest. ▸ Alternatives: `MEDIUM`/`LARGE` (unnecessary for file generation).
- `Image: standard:7.0` — has `jq`. ▸ Alternatives: pin a newer image; or a custom image with extra tooling.
- The buildspec is where the task definition shape lives — change CPU/memory/log config here and in the ECS stack together.

```yaml
Pipeline:
  Source: Provider ECR, RepositoryName ecs-ci-cd-app, ImageTag latest → ImageArtifact
  Build:  Provider CodeBuild (DeployFilesProject) → DeployArtifact
  Deploy: Provider CodeDeployToECS (taskdef.json + appspec.yaml from DeployArtifact, image from ImageArtifact, Image1ContainerName IMAGE1_NAME)
```
- `Source Provider: ECR` / `ImageTag: latest`. ▸ Alternatives: `S3` (zip bundle), `CodeStarSourceConnection` (GitHub) — but ECR-on-push is the event-driven choice here.
- `Image1ContainerName: IMAGE1_NAME` — the placeholder string in `taskdef.json` (`<IMAGE1_NAME>`) that CodeDeploy replaces with the real image URI.

---

### `parent.yaml` + `deployment.yaml`

```yaml
# parent.yaml parameter defaults (the knobs you'll actually tune):
VpcCidr 10.20.0.0/16 ; subnet CIDRs ...
ContainerPort 8080 ; ContainerCpu 512 ; ContainerMemory 1024
DesiredCount 1 ; MinCapacity 1 ; MaxCapacity 4 ; CpuTargetUtilization 60
InitialImage public.ecr.aws/nginx/nginx-unprivileged:stable
TemplateVersion (bumped by the sync workflow each push)
```
- These defaults flow down to the children. ▸ Override any of them in `deployment.yaml` under `parameters:` (GitSync reads that file).
- `InitialImage` — bootstrap placeholder. ▸ Alternatives: any public image that listens on `ContainerPort` and returns 200 on `/` (e.g. `public.ecr.aws/docker/library/httpd`).

```yaml
# deployment.yaml — the GitSync deployment file
template-file-path: infrastructure/templates/parent.yaml
parameters: { ProjectName, TemplatesBaseUrl, GitHubOrg, AppRepoName, TemplateVersion }
```
- `template-file-path` — which template GitSync deploys. ▸ Point at a different parent to swap the whole stack.
- `parameters:` — overrides parent defaults. ▸ Add any parent parameter here to change it without editing the template.
