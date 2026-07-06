# Stack Explained — todo

A **photo-gallery web app** built as a CloudFormation nested-stack system managed by **CloudFormation GitSync**.
Users upload photos via a containerised app on **ECS Fargate**; images land in a private **S3 bucket** served through **CloudFront**; metadata is stored in **RDS PostgreSQL**; every image push triggers an automated **blue/green deployment** through CodePipeline + CodeDeploy.

---

## Architecture overview

| Template | Layer | Deployed by |
|---|---|---|
| `00-bootstrap.yaml` | Pre-requisites | Manually, once |
| `templates/parent.yaml` | Orchestration | CloudFormation GitSync |
| `children/01-network.yaml` | Network | Parent nested stack |
| `children/02-iam.yaml` | IAM | Parent nested stack |
| `children/03-storage.yaml` | Storage | Parent nested stack |
| `children/04-database.yaml` | Database | Parent nested stack |
| `children/05-ecr.yaml` | Registry | Parent nested stack |
| `children/06-alb-ecs.yaml` | Compute | Parent nested stack |
| `children/07-pipeline.yaml` | CI/CD | Parent nested stack |

---

## 00 — Bootstrap (`00-bootstrap.yaml`)

Run **once by hand** before GitSync takes over. Creates the bucket that holds child templates and the CI role that uploads them.

| Resource | Type | What it does |
|---|---|---|
| `TemplatesBucket` | `AWS::S3::Bucket` | Stores the child CloudFormation templates uploaded by GitHub Actions. Versioned, AES256-encrypted, all public access blocked, old versions expire after 30 days. `DeletionPolicy: Retain` so templates survive a bootstrap teardown. |
| `TemplatesBucketPolicy` | `AWS::S3::BucketPolicy` | Denies all non-TLS access. Explicitly allows the `cloudformation.amazonaws.com` service principal to read template objects (required for nested stacks to fetch them). |
| `InfraGitHubActionsRole` | `AWS::IAM::Role` | OIDC role assumed by the **infra repo's** GitHub Actions workflow. Trust scoped to `repo:Adamsmiracle/cloudformation_infra:*`. Grants: template upload to the bucket, and `UpdateStack`/change-set APIs on the parent stack to trigger re-deploys after upload. |

---

## Parent (`templates/parent.yaml`)

Pure orchestration — no AWS resources of its own. Instantiates all 7 children, threads parameters between them via `!GetAtt <Child>.Outputs.<X>`, and bumps `TemplateVersion` on every push to force CloudFormation to re-read nested stacks.

| Resource | Type | What it does |
|---|---|---|
| `NetworkStack` | `AWS::CloudFormation::Stack` | Instantiates the network child template. Receives CIDR parameters; exports VPC id and subnet ids. |
| `IamStack` | `AWS::CloudFormation::Stack` | Instantiates the IAM child template. Receives GitHub org/repo identity; exports all role ARNs. |
| `StorageStack` | `AWS::CloudFormation::Stack` | Instantiates the storage child template. Exports bucket name, bucket ARN, and CloudFront domain. |
| `DatabaseStack` | `AWS::CloudFormation::Stack` | Instantiates the database child template. Receives VPC and private subnet ids from `NetworkStack`; exports RDS endpoint and DB security group id. |
| `EcrStack` | `AWS::CloudFormation::Stack` | Instantiates the ECR child template. Exports repository name and URI. |
| `AlbEcsStack` | `AWS::CloudFormation::Stack` | Instantiates the ALB + ECS child template. Receives networking, IAM role ARNs, and DB security group id; exports ALB DNS, cluster/service names, and target group names. |
| `PipelineStack` | `AWS::CloudFormation::Stack` | Instantiates the pipeline child template. Receives cluster/service/TG names from `AlbEcsStack`, repo name from `EcrStack`, and role ARNs from `IamStack`. |

---

## 01 — Network (`children/01-network.yaml`)

Standard two-AZ VPC with public/private separation and **no NAT gateway** — private subnets reach AWS services exclusively through VPC endpoints, so no task traffic ever traverses the public internet. Every AWS API the tasks call must therefore have a matching endpoint (the gap that NAT used to hide).

| Resource | Type | What it does |
|---|---|---|
| `Vpc` | `AWS::EC2::VPC` | The network boundary — `10.20.0.0/16`, DNS hostnames and resolution enabled. |
| `InternetGateway` | `AWS::EC2::InternetGateway` | Provides the VPC its internet on-ramp. |
| `AttachGateway` | `AWS::EC2::VPCGatewayAttachment` | Attaches the internet gateway to the VPC. |
| `PublicSubnet1` | `AWS::EC2::Subnet` | Public subnet in AZ-a (`10.20.0.0/24`). Hosts the ALB. `MapPublicIpOnLaunch: false`. |
| `PublicSubnet2` | `AWS::EC2::Subnet` | Public subnet in AZ-b (`10.20.1.0/24`). Hosts the ALB. |
| `PrivateSubnet1` | `AWS::EC2::Subnet` | Private subnet in AZ-a (`10.20.10.0/24`). Hosts ECS tasks and RDS. |
| `PrivateSubnet2` | `AWS::EC2::Subnet` | Private subnet in AZ-b (`10.20.11.0/24`). Hosts ECS tasks and RDS. |
| `PublicRouteTable` | `AWS::EC2::RouteTable` | Route table shared by both public subnets. |
| `PublicDefaultRoute` | `AWS::EC2::Route` | Routes `0.0.0.0/0` to the internet gateway for public subnets. |
| `PublicSubnet1Assoc` | `AWS::EC2::SubnetRouteTableAssociation` | Associates `PublicSubnet1` with the public route table. |
| `PublicSubnet2Assoc` | `AWS::EC2::SubnetRouteTableAssociation` | Associates `PublicSubnet2` with the public route table. |
| `PrivateRouteTable` | `AWS::EC2::RouteTable` | Route table shared by both private subnets. Has **no `0.0.0.0/0` route** — only the local route and the S3 gateway-endpoint prefix-list route. Outbound to AWS services goes solely through the interface/gateway endpoints below. |
| `PrivateSubnet1Assoc` | `AWS::EC2::SubnetRouteTableAssociation` | Associates `PrivateSubnet1` with the private route table. |
| `PrivateSubnet2Assoc` | `AWS::EC2::SubnetRouteTableAssociation` | Associates `PrivateSubnet2` with the private route table. |
| `EndpointSecurityGroup` | `AWS::EC2::SecurityGroup` | Controls traffic to interface VPC endpoints — allows HTTPS (port 443) from within the VPC CIDR only. |
| `EcrApiEndpoint` | `AWS::EC2::VPCEndpoint` (Interface) | Private connectivity to the ECR control-plane API (`ecr.api`) — image auth/metadata. One of the **three** legs of an image pull. |
| `EcrDkrEndpoint` | `AWS::EC2::VPCEndpoint` (Interface) | Private connectivity to the ECR Docker registry (`ecr.dkr`) — image manifest. The **actual image layers are fetched from S3**, so the S3 gateway endpoint below is the third leg of every pull. |
| `LogsEndpoint` | `AWS::EC2::VPCEndpoint` (Interface) | Private connectivity to CloudWatch Logs. Container log shipping stays in-VPC. |
| `SecretsManagerEndpoint` | `AWS::EC2::VPCEndpoint` (Interface) | Private connectivity to Secrets Manager. Tasks read DB credentials without leaving the VPC. |
| `SsmMessagesEndpoint` | `AWS::EC2::VPCEndpoint` (Interface) | SSM **Messages** — the Session Manager data channel. Required for ECS Exec (interactive shell into running tasks). **Not** the SSM API. |
| `SsmEndpoint` | `AWS::EC2::VPCEndpoint` (Interface) | SSM **API** (`ssm`) — Parameter Store. The app reads its runtime config via `getParametersByPath` at startup; without this endpoint (and with no NAT) the app hangs on boot. Distinct from `ssmmessages`. |
| `S3GatewayEndpoint` | `AWS::EC2::VPCEndpoint` (Gateway) | Free gateway endpoint for S3, attached to the private route table. Carries image uploads, CloudFront-origin reads, **and the ECR image-layer downloads**. Note: S3 is reached via public S3 IPs, so the task SG must allow `443` egress to them (see `ServiceSecurityGroup`). |

---

## 02 — IAM (`children/02-iam.yaml`)

All **application** IAM roles in one place. Every policy scope uses name-derived ARNs (built from `ProjectName`) so this stack has no dependency on the compute or pipeline stacks and can be created before them.

| Resource | Type | What it does |
|---|---|---|
| `GitHubActionsEcrPushRole` | `AWS::IAM::Role` | OIDC role for the **app repo's** GitHub Actions workflow. Trust scoped to `repo:Adamsmiracle/aws_lab_applications:*`. Allows: ECR image push to the `todo-app` repo, and read/write of the deploy bundle in the deploy-source S3 bucket. Nothing else. |
| `TaskExecutionRole` | `AWS::IAM::Role` | Assumed by the **ECS agent** (not the app container). Attaches the managed `AmazonECSTaskExecutionRolePolicy` — enough to pull images from ECR and write logs to CloudWatch. |
| `TaskRole` | `AWS::IAM::Role` | Assumed by the **running app container**. Grants: ECS Exec SSM channel actions; read/write/delete on image bucket objects; list on the image bucket; read SSM parameters under `/${ProjectName}/*`; read the `rds!db-*` Secrets Manager secret for DB credentials. |
| `CodeDeployRole` | `AWS::IAM::Role` | Service role for CodeDeploy. Attaches the managed `AWSCodeDeployRoleForECS` — lets CodeDeploy orchestrate ECS blue/green traffic shifting. |
| `CodePipelineRole` | `AWS::IAM::Role` | Service role for CodePipeline. Inline policy grants: artifacts bucket R/W, CodeDeploy create/get deployment, ECS describe/update service and task definition, `iam:PassRole` to ECS tasks, ECR describe, and deploy-source bucket read. |
| `EventBridgePipelineRole` | `AWS::IAM::Role` | Lets the EventBridge ECR-push rule call `codepipeline:StartPipelineExecution` on this pipeline only. |

---

## 03 — Storage (`children/03-storage.yaml`)

Private image store behind CloudFront. The bucket is inaccessible directly; browsers always go through CloudFront (enforced by the bucket policy's `AWS:SourceArn` condition).

| Resource | Type | What it does |
|---|---|---|
| `ImageBucket` | `AWS::S3::Bucket` | Private gallery image store. All public access blocked, ACLs disabled (`BucketOwnerEnforced`), AES256 with bucket-key encryption, versioning enabled, old versions expire after 30 days. |
| `OriginAccessControl` | `AWS::CloudFront::OriginAccessControl` | Modern OAC that signs requests to S3 with SigV4 (`SigningBehavior: always`). Replacement for the legacy Origin Access Identity. |
| `Distribution` | `AWS::CloudFront::Distribution` | Serves images over HTTPS only (`redirect-to-https`), HTTP/2+3, IPv6, PriceClass_200, GET/HEAD only, compression enabled, managed CachingOptimized cache policy. Origin is the image bucket via the OAC. |
| `ImageBucketPolicy` | `AWS::S3::BucketPolicy` | Two statements: (1) allows `s3:GetObject` only from this specific CloudFront distribution (matched by `AWS:SourceArn`); (2) denies all non-TLS access. |
| `ImageBucketParam` | `AWS::SSM::Parameter` | Publishes the bucket name to SSM at `/${ProjectName}/image-bucket`. The app reads this at startup rather than having the name baked into the container image. |
| `CloudFrontDomainParam` | `AWS::SSM::Parameter` | Publishes the CloudFront domain to SSM at `/${ProjectName}/cloudfront-domain`. The app uses this when generating image URLs for the gallery. |

---

## 04 — Database (`children/04-database.yaml`)

RDS PostgreSQL for photo metadata. Private, not publicly accessible, credentials fully managed by Secrets Manager.

| Resource | Type | What it does |
|---|---|---|
| `DbSubnetGroup` | `AWS::RDS::DBSubnetGroup` | Places the RDS instance across the two private subnets to support Multi-AZ. |
| `DbSecurityGroup` | `AWS::EC2::SecurityGroup` | DB security group with **no inline ingress** (the port-5432 rule from ECS is added in the compute stack to avoid a cross-stack cycle). Egress locked to `127.0.0.1/32` — RDS never initiates outbound connections. |
| `Database` | `AWS::RDS::DBInstance` | PostgreSQL 16, `db.t3.micro`, 20 GB gp3, storage encrypted, Multi-AZ (configurable), not publicly accessible, 1-day automated backups, `ManageMasterUserPassword: true` — Secrets Manager generates and rotates the master password automatically. |
| `DbEndpointParam` | `AWS::SSM::Parameter` | Publishes the RDS endpoint address to SSM at `/${ProjectName}/db-endpoint`. |
| `DbNameParam` | `AWS::SSM::Parameter` | Publishes the database name to SSM at `/${ProjectName}/db-name`. |
| `DbSecretArnParam` | `AWS::SSM::Parameter` | Publishes the Secrets Manager secret ARN to SSM at `/${ProjectName}/db-secret-arn`. The app resolves this ARN to fetch credentials at startup. |

---

## 05 — ECR (`children/05-ecr.yaml`)

| Resource | Type | What it does |
|---|---|---|
| `EcrRepository` | `AWS::ECR::Repository` | Container image registry named `todo-app`. `MUTABLE` tags so the workflow can overwrite `latest` on every build (the tag CodePipeline tracks). Scan-on-push enabled, AES256 encryption, lifecycle rule retains only the last 10 images. CodeDeploy pins the resolved image digest in the task definition at deploy time, providing rollback safety without per-SHA tags. |

---

## 06 — ALB + ECS (`children/06-alb-ecs.yaml`)

The compute layer: load balancer, Fargate service configured for blue/green, and CPU-based autoscaling. Also owns the inter-security-group ingress rules to break the cross-stack dependency cycle.

| Resource | Type | What it does |
|---|---|---|
| `AlbSecurityGroup` | `AWS::EC2::SecurityGroup` | ALB security group. Allows inbound HTTP `:80` from `0.0.0.0/0`; egress restricted to the container port within the VPC CIDR (to ECS tasks only). |
| `ServiceSecurityGroup` | `AWS::EC2::SecurityGroup` | ECS task security group. Egress: HTTPS `:443` to the VPC CIDR (interface endpoints), HTTPS `:443` to `0.0.0.0/0` (the **S3 gateway endpoint** is reached via public S3 IPs — SGs match the real destination IP, not the route, so this rule is required for ECR layer pulls; safe because the private subnet has no internet route), and PostgreSQL `:5432` to the DB security group. No inline ingress (added by `ServiceIngressFromAlb`). |
| `ServiceIngressFromAlb` | `AWS::EC2::SecurityGroupIngress` | Adds the rule allowing the ALB security group to reach tasks on the container port. Defined separately to avoid a circular reference between the two security groups. |
| `DbIngressFromService` | `AWS::EC2::SecurityGroupIngress` | Adds port-5432 ingress to the **DB security group** from the service security group. Defined here (not in the database stack) because this stack owns the service SG — breaks the cross-stack cycle. |
| `LoadBalancer` | `AWS::ElasticLoadBalancingV2::LoadBalancer` | Internet-facing Application Load Balancer across the two public subnets. Drops invalid header fields, 60-second idle timeout. |
| `TargetGroupBlue` | `AWS::ElasticLoadBalancingV2::TargetGroup` | The "blue" (current live) target group. IP-mode targets (Fargate), health check on `/` expecting HTTP 200, 30-second deregistration delay. |
| `TargetGroupGreen` | `AWS::ElasticLoadBalancingV2::TargetGroup` | The "green" (new deployment) target group. Same config as blue. Both kept on port 80 to avoid CloudFormation's immutable-port replacement during updates. |
| `HttpListener` | `AWS::ElasticLoadBalancingV2::Listener` | HTTP `:80` listener on the ALB. Forwards to the blue target group by default; CodeDeploy swaps it to green during deployments. |
| `LogGroup` | `AWS::Logs::LogGroup` | CloudWatch log group `/ecs/${ProjectName}` for container logs, 14-day retention. |
| `Cluster` | `AWS::ECS::Cluster` | The Fargate cluster. Container Insights enabled for enhanced CloudWatch metrics. |
| `Service` | `AWS::ECS::Service` | The Fargate service. `DeploymentController: CODE_DEPLOY` (CloudFormation hands off deployment control to CodeDeploy). 100/200% min/max healthy percent, ECS Exec enabled, runs in private subnets with no public IP, registered to the blue target group. **No `TaskDefinition` property** — the task definition is not managed here; CodeDeploy registers it from the `taskdef.json` the app repo ships. CloudFormation cannot update a `TaskDefinition` on a CODE_DEPLOY service, so the property is omitted entirely to avoid update failures. |
| `ScalableTarget` | `AWS::ApplicationAutoScaling::ScalableTarget` | Registers the ECS service for Application Auto Scaling between `MinCapacity` and `MaxCapacity` tasks. `MinCapacity: 2` (set in `deployment.yaml`) ensures there are always 2 warm tasks so blue/green never drops to zero healthy. |
| `CpuScalingPolicy` | `AWS::ApplicationAutoScaling::ScalingPolicy` | Target-tracking policy on average CPU utilisation (target: `CpuTargetUtilization`, default 60%). 60-second scale-in and scale-out cooldowns. Adds tasks when CPU rises, removes them when it falls back. |

---

## 07 — Pipeline (`children/07-pipeline.yaml`)

Fully automated CI/CD: an ECR image push triggers an end-to-end blue/green deployment with no manual approval gate.

| Resource | Type | What it does |
|---|---|---|
| `ArtifactBucket` | `AWS::S3::Bucket` | CodePipeline's internal artifact store. Versioned, encrypted, public access blocked, artifacts expire after 30 days (non-current versions after 7 days). |
| `ArtifactBucketPolicy` | `AWS::S3::BucketPolicy` | Denies all non-TLS access to the artifact bucket. |
| `DeploySourceBucket` | `AWS::S3::Bucket` | Holds `deploy-bundle.zip` (`taskdef.json` + `appspec.yaml`) uploaded by the app repo's GitHub Actions workflow. Versioning **required** for the CodePipeline S3 source action. |
| `DeploySourceBucketPolicy` | `AWS::S3::BucketPolicy` | Denies all non-TLS access to the deploy-source bucket. |
| `CodeDeployApp` | `AWS::CodeDeploy::Application` | The CodeDeploy application for ECS compute platform. |
| `CodeDeployDeploymentGroup` | `AWS::CodeDeploy::DeploymentGroup` | Blue/green deployment group wired to the ECS service and both target groups. Traffic shifts automatically once green is healthy (`CONTINUE_DEPLOYMENT`). Blue tasks are terminated 5 minutes after a successful shift. Auto-rollback on deployment failure or alarm. |
| `EcrImagePushRule` | `AWS::Events::Rule` | EventBridge rule that fires on a successful ECR `PUSH` of the `latest` tag to the app repository. This is the **single deployment trigger** — it starts the pipeline via the EventBridge role. |
| `Pipeline` | `AWS::CodePipeline::Pipeline` | Two-stage pipeline. **Source** (parallel): `EcrSource` pulls `latest` image metadata from ECR; `DeploySource` reads `deploy-bundle.zip` from S3 (polling off — ECR push is the only trigger). **Deploy**: `CodeDeployToECS` performs the blue/green swap using `taskdef.json` and `appspec.yaml`, substituting the new image digest into `IMAGE1_NAME`. |

---

## End-to-end flow

```
Infra change  → push to infra repo
              → GHA uploads child templates to TemplatesBucket
              → bumps TemplateVersion, triggers UpdateStack
              → CloudFormation re-deploys affected nested stacks

App change    → push to app repo
              → GHA builds image, pushes `latest` to ECR
              → GHA uploads deploy-bundle.zip to DeploySourceBucket

ECR push      → EventBridge EcrImagePushRule fires
              → CodePipeline starts
              → Source: pulls new image metadata + deploy bundle
              → Deploy: CodeDeploy blue/green on ECS service
                  green tasks start, pass health checks
                  ALB listener shifts from blue → green
                  blue tasks terminate after 5 min

User traffic  → ALB (HTTP) → ECS Fargate tasks (app)
Images served → CloudFront → private S3 ImageBucket
Metadata      → ECS tasks ↔ RDS PostgreSQL (private subnets)
Config        → ECS tasks read SSM params at startup
DB creds      → ECS tasks read Secrets Manager at startup
```
