# AWS breadcrumbs: every command, in order, explained

This is the trail of every AWS action in this project, in the order it happened.
For each step you get:

- **What & why**: what the piece is and why it exists
- **CLI**: the exact command that was run (or will be run)
- **Console**: the same thing done by clicking, so you can find it in the UI
- **Check**: a command that proves it worked

Status markers: ✅ done · ❌ failed first (the error and the fix are the interview story) · 🔜 planned

> Every command assumes these two lines first. They pick the limited IAM user and the region.
> ```bash
> export AWS_PROFILE=station-stream   # use ~/.aws credentials for station-stream-dev, never root
> export AWS_REGION=us-east-1         # N. Virginia. Everything lives here.
> ```

## Resource IDs (not secrets, just names)

| Name | Value |
|---|---|
| Account | `897744507899` |
| Default VPC | `vpc-05badfb7b5abe5ec2` |
| Subnets used | `subnet-0bd6fc96d336612c9` (us-east-1a), `subnet-07cd6ba224b429970` (us-east-1b) |
| Load balancer security group | `sg-0e74dafa314f5550d` (`station-stream-alb`) |
| Task security group | `sg-0f9f51d3b947f0b80` (`station-stream-task`) |
| Target group | `arn:aws:elasticloadbalancing:us-east-1:897744507899:targetgroup/station-stream-tg/50a7c24c042c2783` |
| Load balancer | `arn:aws:elasticloadbalancing:us-east-1:897744507899:loadbalancer/app/station-stream-alb/09b5d527936ae1a4` |
| Public URL | http://station-stream-alb-565835838.us-east-1.elb.amazonaws.com |
| ECR repo | `897744507899.dkr.ecr.us-east-1.amazonaws.com/station-stream` |
| GitHub deploy role | `arn:aws:iam::897744507899:role/station-stream-github-deploy` (OIDC provider `token.actions.githubusercontent.com`) |
| Video bucket | `station-stream-video-897744507899` |
| **App 2 (Terraform)** | http://station-stream-tf-alb-862429135.us-east-1.elb.amazonaws.com · **API over HTTPS https://d1436kyrcdypmk.cloudfront.net** (`E7BB4SHJWN2O6`) · video CloudFront `d990usezj0kzv.cloudfront.net` · everything named `station-stream-tf-*` · state in `terraform/terraform.tfstate` |
| CloudFront distribution | `E285IGXEWUIGEW` → https://d22r43ct06qav3.cloudfront.net (OAC `E10UJH60KSW2B5`) |

---

## Phase 0: Account safety (done as root, in the console and CloudShell)

### 0.1 ✅ $10 monthly budget, measured before credits

**What & why:** AWS Budgets emails you when spending crosses a line. This is a Free plan account with $100 in credits, and a normal budget measures spending *after* credits, so it would sit at $0 and never alert. `IncludeCredit:false` makes it count real usage.

**Why CLI here:** the console's "exclude credits" filter needs Cost Explorer, which only switches on about 24 hours after a new account is created. The API doesn't need it. Root has no access keys, so this ran in **CloudShell**, a terminal in the browser that's already signed in as you.

```bash
# Look up the account number of whoever is signed in
ACCT=$(aws sts get-caller-identity --query Account --output text)

# Create a $10/month cost budget that ignores credits and refunds
aws budgets create-budget --account-id $ACCT --budget '{
  "BudgetName": "station-stream-10usd",
  "BudgetLimit": {"Amount": "10", "Unit": "USD"},
  "TimeUnit": "MONTHLY",
  "BudgetType": "COST",
  "CostTypes": {"IncludeCredit": false, "IncludeRefund": false}
}'

# Add 3 email alerts: 85% actual, 100% actual, 100% forecast
for n in ACTUAL:85 ACTUAL:100 FORECASTED:100; do
  aws budgets create-notification --account-id $ACCT --budget-name station-stream-10usd \
    --notification NotificationType=${n%%:*},ComparisonOperator=GREATER_THAN,Threshold=${n##*:},ThresholdType=PERCENTAGE \
    --subscribers SubscriptionType=EMAIL,Address=julius@ranklab.org
done
```

**Console:** Billing and Cost Management → Budgets → Create budget → Customize (advanced) → Cost budget → amount 10 → Budget scope → Filter specific AWS cost dimensions → Charge type → **Excludes** → Credit. That last step is the one that failed on day one.

**Check:**
```bash
aws budgets describe-notifications-for-budget --account-id $ACCT --budget-name station-stream-10usd --output table
```

### 0.2 ✅ Limited IAM user (you clicked these; here's the CLI version for learning)

**What & why:** IAM (Identity and Access Management) controls who can do what. Root can do anything, including closing the account, so daily work happens as `station-stream-dev`. Permissions go on a **group** and the user inherits them, so adding a second person later is one click.

```bash
# A group is a bundle of permissions
aws iam create-group --group-name station-stream-builders

# 7 AWS-managed policies, one per service this project uses
for p in AmazonEC2ContainerRegistryFullAccess AmazonECS_FullAccess ElasticLoadBalancingFullAccess \
         AmazonVPCFullAccess AmazonS3FullAccess CloudFrontFullAccess CloudWatchFullAccessV2; do
  aws iam attach-group-policy --group-name station-stream-builders --policy-arn arn:aws:iam::aws:policy/$p
done

# Our own inline policy: IAM writes only on roles named station-stream-*
# (stops the user from making itself an admin)
aws iam put-group-policy --group-name station-stream-builders --policy-name station-stream-iam-scoped \
  --policy-document file://infra/iam/builder-iam-scoped.json

# The user, added to the group
aws iam create-user --user-name station-stream-dev
aws iam add-user-to-group --user-name station-stream-dev --group-name station-stream-builders

# Access key for the CLI. Only YOU run this; the secret is shown once and goes into `aws configure`
aws iam create-access-key --user-name station-stream-dev
```

**Console:** IAM → User groups → Create group. Then IAM → Users → Create user → Security credentials → Create access key.

### 0.3 ✅ Connect the CLI, then prove the limits

```bash
aws configure --profile station-stream     # paste the keys; region us-east-1; output json
aws sts get-caller-identity                # Arn should end in user/station-stream-dev (NOT root)

# Negative tests: both SHOULD fail with AccessDenied
aws iam create-user --user-name should-not-exist
aws iam create-role --role-name evil-admin --assume-role-policy-document '{...}'
```

**How to read an AccessDenied:** the message names the exact **action** (`iam:CreateRole`), the **resource** (`role/evil-admin`), and the **reason** ("no identity-based policy allows"). That tells you which policy line to add or fix.

---

## Phase 4: ECR, the private image registry

### 4.1 ✅ Create the repository

**What & why:** ECR (Elastic Container Registry) stores Docker images privately. ECS pulls from it.
- `IMMUTABLE` means a tag can never be overwritten, so version `57b8b14` is always the same bytes and rollbacks are exact.
- `scanOnPush` checks every image for known security holes (CVEs, the public list of known vulnerabilities).

```bash
aws ecr create-repository --repository-name station-stream \
  --image-tag-mutability IMMUTABLE \
  --image-scanning-configuration scanOnPush=true \
  --tags Key=project,Value=station-stream
```

**Console:** ECR → Private registry → Repositories → Create repository → Tag immutability: Immutable → Scan on push: on.

### 4.2 ✅ Lifecycle policy (cost guardrail)

```bash
# Keep only the 10 newest images; older ones expire automatically
aws ecr put-lifecycle-policy --repository-name station-stream --lifecycle-policy-text '{
  "rules": [{"rulePriority": 1, "description": "keep last 10 images",
             "selection": {"tagStatus": "any", "countType": "imageCountMoreThan", "countNumber": 10},
             "action": {"type": "expire"}}]}'
```

**Console:** the repository → Lifecycle policy → Create rule.

### 4.3 ✅ Log Docker in, tag with the git commit, push

```bash
REG=897744507899.dkr.ecr.us-east-1.amazonaws.com
TAG=$(git rev-parse --short HEAD)      # e.g. 57b8b14: every image traces back to a commit

# Exchange IAM credentials for a Docker password that expires after 12 hours
aws ecr get-login-password | docker login --username AWS --password-stdin $REG

# --provenance=false: one plain image per push (see the ❌ below)
docker build --platform linux/arm64 --provenance=false -t $REG/station-stream:$TAG .
docker push $REG/station-stream:$TAG
```

**Console:** the repository → **View push commands** shows these same commands.

### 4.4 ❌→✅ Provenance attestation gotcha

**What happened:** the first push created 3 entries: a tagged *index* plus two untagged children (the real image and a build-metadata record). The scan reported "not found" because it scans the real image, not the index. Worse, the lifecycle policy counts untagged children, so it could have deleted the real image while a tag still pointed at it, leaving ECS unable to pull.

```bash
# How I saw it: list every entry, including untagged ones
aws ecr describe-images --repository-name station-stream \
  --query 'imageDetails[].[imageTags[0]||`(untagged)`, imageManifestMediaType]' --output text

# The fix: delete the 3 entries and rebuild with --provenance=false
aws ecr batch-delete-image --repository-name station-stream --image-ids imageDigest=sha256:...
```

### 4.5 ❌→✅ Vulnerability scan found a HIGH CVE

```bash
aws ecr describe-image-scan-findings --repository-name station-stream --image-id imageTag=51b2e63 \
  --query 'imageScanFindings.findingSeverityCounts'
# → {"HIGH": 1}: zlib 1.3.2-r0 in the Alpine base image
```

**Fix:** `RUN apk upgrade --no-cache` in the Dockerfile picks up Alpine's patched zlib (r1). The new tag `57b8b14` scans **clean**.

**Proving immutability:** pushing a different image as `51b2e63` was refused with *"cannot be overwritten because the tag is immutable"*.

---

## Phase 5: ECS Fargate behind a load balancer (billing ≈ $0.05/hour)

Order matters: **network → firewalls → role → logs → cluster → load balancer → task definition → service.** Each piece depends on the ones before it.

### 5.1 ✅ Find the network (read-only)

**What & why:** a VPC (Virtual Private Cloud) is your private network in AWS. Every account has a *default VPC* with one public subnet per Availability Zone (a separate data center). The load balancer must span at least 2 zones.

```bash
aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text
aws ec2 describe-subnets --filters Name=vpc-id,Values=vpc-05badfb7b5abe5ec2 \
  --query 'Subnets[].[AvailabilityZone,SubnetId,MapPublicIpOnLaunch]' --output table
```

**Console:** VPC → Your VPCs (the one marked "Default VPC: Yes") → Subnets.

### 5.2 ✅ Two security groups (firewalls)

**What & why:** a security group allows only what you list. Two are chained together:
- **ALB group:** port 80 from anywhere (`0.0.0.0/0`).
- **Task group:** port 4000 only from the **ALB group**. The source is a group ID, not an IP range, so the container can't be reached directly even though it has a public IP.

```bash
ALB_SG=$(aws ec2 create-security-group --group-name station-stream-alb \
  --description "Public HTTP to the load balancer" --vpc-id vpc-05badfb7b5abe5ec2 \
  --query GroupId --output text)

TASK_SG=$(aws ec2 create-security-group --group-name station-stream-task \
  --description "Only the load balancer may reach the API task" --vpc-id vpc-05badfb7b5abe5ec2 \
  --query GroupId --output text)

# Inbound rule: internet → load balancer on 80
aws ec2 authorize-security-group-ingress --group-id $ALB_SG --protocol tcp --port 80 --cidr 0.0.0.0/0

# Inbound rule: load balancer group → task on 4000 (note --source-group, not --cidr)
aws ec2 authorize-security-group-ingress --group-id $TASK_SG --protocol tcp --port 4000 --source-group $ALB_SG
```

**Console:** EC2 → Security Groups → Create security group → Inbound rules → Add rule. For the task group, set **Source** to "Custom" and pick `station-stream-alb` from the list.

**Check:** get the task's public IP, then `curl http://<task-ip>:4000/health`. It **times out**, which proves the firewall works.

### 5.3 ✅ Task execution role

**What & why:** a *role* is a set of permissions that a service takes on temporarily, so no keys are stored. **ECS itself** uses the *execution role* to pull the image from ECR and send logs to CloudWatch. It has two parts:
- **Trust policy** ([infra/iam/task-exec-trust.json](../infra/iam/task-exec-trust.json)): *who* may use the role. Only `ecs-tasks.amazonaws.com`, and only for this account. The `aws:SourceAccount` condition prevents the "confused deputy" attack, where another account tricks AWS into using your role.
- **Permissions:** AWS's managed `AmazonECSTaskExecutionRolePolicy`.

```bash
aws iam create-role --role-name station-stream-task-exec \
  --assume-role-policy-document file://infra/iam/task-exec-trust.json
aws iam attach-role-policy --role-name station-stream-task-exec \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
```

This worked only because the name starts with `station-stream-`. The Phase 0 scoped policy refuses any other name.

**Console:** IAM → Roles → Create role → AWS service → Elastic Container Service → **Elastic Container Service Task** → attach `AmazonECSTaskExecutionRolePolicy`.

### 5.4 ✅ Log group with retention

```bash
aws logs create-log-group --log-group-name /ecs/station-stream
aws logs put-retention-policy --log-group-name /ecs/station-stream --retention-in-days 7   # default is forever, and billed
```

**Console:** CloudWatch → Logs → Log groups → Create log group.

### 5.5 ✅ Cluster

**What & why:** with Fargate there are no servers to manage, so a cluster is just a named grouping for services and tasks.

```bash
aws ecs create-cluster --cluster-name station-stream
```

**Console:** ECS → Clusters → Create cluster → infrastructure: **AWS Fargate (serverless)**.

### 5.6 ✅ Target group (the list of healthy containers)

**What & why:** the load balancer sends traffic to whatever is *healthy* in this group.
- `target-type ip`: each Fargate task gets its own network address.
- Health checks: `/health` every 15 seconds. 2 passes mark a task healthy; 3 failures mark it unhealthy.

```bash
TG_ARN=$(aws elbv2 create-target-group --name station-stream-tg --protocol HTTP --port 4000 \
  --vpc-id vpc-05badfb7b5abe5ec2 --target-type ip \
  --health-check-path /health --health-check-interval-seconds 15 \
  --healthy-threshold-count 2 --unhealthy-threshold-count 3 --matcher HttpCode=200 \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

# Deregistration delay: how long a draining task keeps finishing requests. Default 300s
# makes every deploy wait 5 minutes; our requests take milliseconds.
aws elbv2 modify-target-group-attributes --target-group-arn $TG_ARN \
  --attributes Key=deregistration_delay.timeout_seconds,Value=30
```

**Console:** EC2 → Target Groups → Create → target type **IP addresses** → health check path `/health` → **don't register targets** (ECS does that automatically).

### 5.7 ❌→✅ Application Load Balancer

**What & why:** the public front door. It spans 2 zones and gets a DNS name. 💰 This is the main hourly cost (~$0.023/hr).

```bash
# ❌ First try, written zsh-style:
SUBNETS="subnet-0bd6fc96d336612c9 subnet-07cd6ba224b429970"
aws elbv2 create-load-balancer --name station-stream-alb --subnets $SUBNETS ...
#   → InvalidSubnet: The subnet ID 'subnet-0bd6… subnet-07cd…' is not valid
#   Why: zsh does NOT split $SUBNETS on spaces (bash does), so AWS got ONE id with a space in it.

# ✅ Fix: pass each subnet as its own word
aws elbv2 create-load-balancer --name station-stream-alb --type application --scheme internet-facing \
  --subnets subnet-0bd6fc96d336612c9 subnet-07cd6ba224b429970 \
  --security-groups sg-0e74dafa314f5550d
```

**Console:** EC2 → Load Balancers → Create → **Application Load Balancer** → Internet-facing → pick 2 subnets → security group `station-stream-alb`.

### 5.8 ✅ Listener (port 80 → target group)

```bash
aws elbv2 create-listener --load-balancer-arn <ALB_ARN> --protocol HTTP --port 80 \
  --default-actions Type=forward,TargetGroupArn=<TG_ARN>
```

**Console:** this is the "Listeners and routing" section of the load balancer wizard.

### 5.9 ✅ Task definition (the container's spec)

**What & why:** the image, CPU/memory, ARM chip, port, environment variables, and log destination, all in [infra/ecs/taskdef.json](../infra/ecs/taskdef.json). Each registration creates a new numbered **revision** (`:1`, `:2`, …), so a deploy is "point the service at revision N".

```bash
aws ecs register-task-definition --cli-input-json file://infra/ecs/taskdef.json
```

**Console:** ECS → Task definitions → Create new task definition → **Create with JSON** (paste the file), or fill in the form.

### 5.10 ❌→✅ Service (keeps 1 task running, self-healing)

```bash
# ❌ First try included --enable-execute-command
#   → InvalidParameterException: a valid taskRoleArn is not being used
#   Why: ECS Exec (shelling into a container) needs a TASK role, which your app's code uses.
#   The EXECUTION role is what ECS itself uses (pull image, write logs). Our app never calls AWS,
#   so I dropped the flag instead of creating a role we don't need.

# ✅
aws ecs create-service --cluster station-stream --service-name api \
  --task-definition station-stream:1 --desired-count 1 --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[subnet-0bd6fc96d336612c9,subnet-07cd6ba224b429970],securityGroups=[sg-0f9f51d3b947f0b80],assignPublicIp=ENABLED}" \
  --load-balancers "targetGroupArn=<TG_ARN>,containerName=api,containerPort=4000" \
  --health-check-grace-period-seconds 30 \
  --deployment-configuration "deploymentCircuitBreaker={enable=true,rollback=true},minimumHealthyPercent=100,maximumPercent=200"
```

| Setting | Why |
|---|---|
| `assignPublicIp=ENABLED` | The task needs internet access to pull from ECR. The alternative, a NAT gateway, costs ~$32/month. The firewall still blocks everything except the load balancer. |
| `deploymentCircuitBreaker … rollback=true` | If a new version keeps failing to start, ECS stops the deploy and rolls back on its own. |
| `health-check-grace-period 30` | Don't count failed health checks while the app is still booting. |
| `minimumHealthyPercent=100, maximumPercent=200` | During a deploy, start the new task *before* stopping the old one, so there's no downtime. |

**Console:** ECS → Clusters → station-stream → Services → Create → Launch type FARGATE → Networking (subnets, `station-stream-task` group, Public IP **on**) → Load balancing → existing load balancer and target group.

### 5.11 ✅ Watch it come up, then test

```bash
# Task lifecycle: PROVISIONING → PENDING (pulling image) → ACTIVATING → RUNNING
aws ecs list-tasks --cluster station-stream --service-name api
aws ecs describe-tasks --cluster station-stream --tasks <task-arn> --query 'tasks[0].lastStatus'

# Target health: initial → healthy (took ~1m40s)
aws elbv2 describe-target-health --target-group-arn <TG_ARN>

# The service's own diary: the first place to look when anything goes wrong
aws ecs describe-services --cluster station-stream --services api --query 'services[0].events[0:5].message'

curl http://station-stream-alb-565835838.us-east-1.elb.amazonaws.com/health
```

**Console:** ECS → Clusters → station-stream → Services → api → tabs **Health and metrics**, **Tasks**, **Events**, **Logs**.

---

## Phase 6 ✅: S3 + CloudFront for video

**Why:** the public page's video links still point to `http://localhost:8080`, which browsers block (`ERR_BLOCKED_BY_CLIENT`). Video moves to S3, served through CloudFront.

### 6.1 ✅ Private S3 bucket (done in the console)

**What & why:** S3 (Simple Storage Service) holds the HLS files. **Block Public Access** stays on: nobody reads the bucket directly, only CloudFront.

**Console (what was clicked):** S3 → Create bucket →
- Bucket type **General purpose**; namespace **Global** (the newer "Account Regional" namespace stops other accounts from claiming your names; kept Global so the name matches this plan)
- Name `station-stream-video-897744507899` (bucket names are shared worldwide, so the account number makes it unique)
- Object Ownership **ACLs disabled** (access decided only by policies, AWS's recommendation)
- **Block all public access: on** (all 4 sub-settings)
- Versioning **off** (old copies of re-encodable video would only cost money)
- Encryption **SSE-S3**, not SSE-KMS: with KMS, CloudFront would also need permission on the key, a common OAC mistake
- Tag `project=station-stream`

**CLI equivalent:**
```bash
BUCKET=station-stream-video-897744507899
aws s3api create-bucket --bucket $BUCKET       # us-east-1 needs no LocationConstraint
aws s3api put-public-access-block --bucket $BUCKET --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-tagging --bucket $BUCKET --tagging 'TagSet=[{Key=project,Value=station-stream}]'
```

**Check:**
```bash
aws s3api get-public-access-block --bucket $BUCKET          # all four true
aws s3api get-bucket-ownership-controls --bucket $BUCKET    # BucketOwnerEnforced
aws s3api get-bucket-encryption --bucket $BUCKET            # AES256 (= SSE-S3)
```

### 6.2 ✅ Upload video with correct content types (CLI: bulk work, 141 files / 120 MB)

**What & why:** every S3 object carries a `Content-Type` header that tells the browser what it is. `.ts` is a classic trap: tools guess **TypeScript**, not video, and some players refuse it. So each file type is uploaded separately with its type set explicitly. `Cache-Control` tells CloudFront and browsers how long to keep a copy: segments never change once made (1 year), playlists might (5 minutes).

```bash
# sync uploads only new or changed files, so re-running is cheap
aws s3 sync video/out s3://$BUCKET --exclude "*" --include "*.ts" \
  --content-type video/mp2t --cache-control "public,max-age=31536000,immutable"
aws s3 sync video/out s3://$BUCKET --exclude "*" --include "*.m3u8" \
  --content-type application/vnd.apple.mpegurl --cache-control "public,max-age=300"
aws s3 sync video/out s3://$BUCKET --exclude "*" --include "*.jpg" \
  --content-type image/jpeg --cache-control "public,max-age=86400"
```

**Console:** bucket → Upload → Add folder. Content type and Cache-Control are under **Properties → Metadata**, and you'd have to set them per batch, which is why bulk uploads belong in the CLI.

**Check:**
```bash
aws s3 ls s3://$BUCKET --recursive --summarize | tail -2              # 141 objects, ~120 MB
aws s3api head-object --bucket $BUCKET --key ship-it/1080p/seg_000.ts \
  --query '[ContentType,CacheControl]'                                 # video/mp2t, max-age=31536000
```

### 6.3 ✅ CloudFront with Origin Access Control (done in the console)

**What & why:** CloudFront is AWS's CDN: copies of the video sit in data centers near viewers. **Origin Access Control (OAC)** makes CloudFront sign every request to S3, and the bucket policy accepts *only this distribution's* signed requests.

Result: distribution `E285IGXEWUIGEW` → **https://d22r43ct06qav3.cloudfront.net**, OAC `E10UJH60KSW2B5`.

**Console (what was clicked):** CloudFront → Create distribution (the newer 4-step wizard):
1. **Get started:** name `station-stream-video`; type **Single website** (the "Multiple website configuration" option is AWS's built-in multi-brand/SaaS mode, essentially Local Public's 20-stations-one-platform model); no custom domain (use the free `*.cloudfront.net` with HTTPS).
2. **Specify origin:** type **Amazon S3** → Browse S3 → the bucket. **"Allow private S3 bucket access to CloudFront"** ticked: this creates the OAC *and* writes the bucket policy, replacing the old copy-paste step. Origin settings: recommended. Cache settings: **Customize**:
   - Viewer protocol **Redirect HTTP to HTTPS**
   - Allowed methods **GET, HEAD, OPTIONS** (OPTIONS = the browser's CORS "preflight" permission check)
   - Cache policy **CachingOptimized** (cache key = URL only; respects each object's Cache-Control)
   - Response headers policy **CORS-With-Preflight**: adds `Access-Control-Allow-Origin` so hls.js on the ALB's domain may read the files. Without it the browser blocks the video as cross-origin.
3. **Enable security:** **Do not enable** WAF (Web Application Firewall, ~$14/month). Public video in a private bucket has no forms or logins to attack; in production with sign-in you'd turn it on.
4. **Review:** Billing **Pay-as-you-go ($0/month)**, Origin Shield **off** (an extra paid cache layer for huge audiences).

Then Tags tab → Manage tags → add `project=station-stream` (the wizard only adds `Name`).

Price class defaulted to **All edge locations** (`PriceClass_All`). `PriceClass_100` (North America + Europe only) is cheaper at scale; at our traffic the free tier covers either.

**The bucket policy CloudFront wrote:**
```json
{
  "Effect": "Allow",
  "Principal": { "Service": "cloudfront.amazonaws.com" },
  "Action": "s3:GetObject",
  "Resource": "arn:aws:s3:::station-stream-video-897744507899/*",
  "Condition": { "ArnLike": { "AWS:SourceArn": "arn:aws:cloudfront::897744507899:distribution/E285IGXEWUIGEW" } }
}
```
Only `GetObject`, no `ListBucket`: a **missing file returns 403, not 404**, so outsiders can't probe which files exist. Remember that when debugging a broken link.

**CLI equivalent:**
```bash
aws cloudfront create-origin-access-control --origin-access-control-config \
  Name=station-stream-oac,SigningProtocol=sigv4,SigningBehavior=always,OriginAccessControlOriginType=s3
aws cloudfront create-distribution-with-tags --distribution-config-with-tags file://distribution.json
#   origin = bucket + the OAC id; ViewerProtocolPolicy=redirect-to-https;
#   CachePolicyId = Managed-CachingOptimized (658327ea-f89d-4fab-a63d-7e88639e58f6);
#   ResponseHeadersPolicyId = Managed-CORS-With-Preflight (5cc3b908-e619-4b99-88e5-2cf7f45965bd)
aws s3api put-bucket-policy --bucket $BUCKET --policy file://bucket-policy.json   # the JSON above
```

**Check:**
```bash
aws s3api get-bucket-policy --bucket $BUCKET --query Policy --output text | python3 -m json.tool
aws cloudfront get-distribution --id E285IGXEWUIGEW --query 'Distribution.Status'    # InProgress → Deployed
curl -I https://d22r43ct06qav3.cloudfront.net/ship-it/master.m3u8                     # 200 via CloudFront
curl -I https://station-stream-video-897744507899.s3.amazonaws.com/ship-it/master.m3u8 # 403 straight from S3
```

### 6.4 ✅ Rolling deploy with the new video URL (done in the console)

**What & why:** the API reads `VIDEO_BASE_URL` from the task definition. Task definitions can't be edited, only given a new **revision**; pointing the service at it triggers a **rolling deploy**. Same image (`57b8b14`): this is a *config* change, not a code change.

**Console (what was clicked):**
1. ECS → Task definitions → station-stream → revision 1 → **Create new revision** → Environment variables → `VIDEO_BASE_URL` = `https://d22r43ct06qav3.cloudfront.net` → Create → **`station-stream:2`**. (Value type "Value" = plain text; "ValueFrom" would pull a secret from Secrets Manager/Parameter Store.)
2. ECS → Clusters → station-stream → Services → api → **Update service** → Task definition revision: type `2`, pick **"2 (Latest)"** from the dropdown (typing alone doesn't select it) → Update.

**CLI equivalent:**
```bash
aws ecs register-task-definition --cli-input-json file://infra/ecs/taskdef.json   # → revision 2
aws ecs update-service --cluster station-stream --service api --task-definition station-stream:2
```

**What the rollout looked like** (polled every ~12s):
```
17:26:46  new task 172.31.89.204 registers → healthy; old 172.31.90.9 still healthy (both serving)
17:26:58–17:27:34  API answers alternate localhost ↔ cloudfront   ← version skew: the ALB round-robins old and new
17:27:44  old task deregistered → draining (30s deregistration delay)
17:28:36  "deployment completed" / "has reached a steady state"   ~2.5 min total, zero downtime
```
**Version skew** is normal in rolling deploys: for ~50s users could hit either version, which is why a new API version must stay backward-compatible with clients of the old one.

**Check:**
```bash
aws ecs describe-services --cluster station-stream --services api \
  --query 'services[0].deployments[].[taskDefinition,rolloutState,runningCount]'   # one entry: :2 COMPLETED 1
curl -s http://station-stream-alb-565835838.us-east-1.elb.amazonaws.com/graphql \
  -H 'content-type: application/json' -d '{"query":"{ show(slug:\"code-lab\"){ imageUrl } }"}'   # cloudfront URL
```
Player status line on the public URL: **"720p @ 3306 kbps · 2 renditions · auto · from d22r43ct06qav3.cloudfront.net"**.

---

## Phase 7 ✅: Monitoring, alarms, autoscaling, self-healing

### 7.1 ❌→✅ SNS topic for alerts

**What & why:** SNS (Simple Notification Service) is publish/subscribe. Alarms *publish* to a topic; everything *subscribed* (email now, PagerDuty/Slack in production) gets the message. Alarms don't need to know who's listening.

**Console:** SNS → Topics → Create topic → Type **Standard** (the default is **FIFO**, which preserves order but **can't deliver email**) → Name `station-stream-alerts` → Display name `StationStrm` (SMS shows only 10 characters) → Encryption off, Access policy Basic → Tags `project=station-stream` → Create topic.

**Red herring on page load:** a red banner `Couldn't retrieve KMS keys … not authorized to perform kms:DescribeKey`. The form tries to list KMS keys to fill its optional encryption dropdown. We aren't using a custom key, so it changes nothing. Read *which action* failed before deciding whether an error matters.

**❌ The real failure on Create topic:**
```
AuthorizationError: User: …user/station-stream-dev is not authorized to perform: SNS:TagResource
on resource: arn:aws:sns:us-east-1:897744507899:station-stream-alerts
because no identity-based policy allows the SNS:TagResource action
```
**Diagnosis:** our SNS rights come from the managed `CloudWatchFullAccessV2`. Instead of guessing, read what it actually grants:
```bash
ARN=arn:aws:iam::aws:policy/CloudWatchFullAccessV2
V=$(aws iam get-policy --policy-arn $ARN --query Policy.DefaultVersionId --output text)
aws iam get-policy-version --policy-arn $ARN --version-id $V --query 'PolicyVersion.Document.Statement[].Action'
# → SNS: CreateTopic, Subscribe, ListTopics, ListSubscriptions, ListSubscriptionsByTopic. That's all.
```
Two gaps: `TagResource` (today's error) and **`DeleteTopic`/`Unsubscribe`, so teardown would have failed later too.** The failed create was all-or-nothing: no topic exists.

**Fix:** a new statement in [infra/iam/builder-iam-scoped.json](../infra/iam/builder-iam-scoped.json), scoped to topics named `station-stream-*` (same pattern as the IAM roles):
```json
{ "Sid": "ManageStationStreamTopics", "Effect": "Allow",
  "Action": ["sns:TagResource","sns:UntagResource","sns:ListTagsForResource","sns:GetTopicAttributes",
             "sns:SetTopicAttributes","sns:DeleteTopic","sns:GetSubscriptionAttributes","sns:Unsubscribe"],
  "Resource": "arn:aws:sns:us-east-1:897744507899:station-stream-*" }
```
Applied by the owner (permission changes are blocked for Claude): IAM → User groups → station-stream-builders → Permissions → `station-stream-iam-scoped` → Edit → JSON → paste → Next → Save changes.
```bash
# CLI equivalent (run as an admin, not as station-stream-dev):
aws iam put-group-policy --group-name station-stream-builders --policy-name station-stream-iam-scoped \
  --policy-document file://infra/iam/builder-iam-scoped.json
```

**✅ Retry:** Create topic succeeded *with* the tag, which proves the policy change applied. Topic ARN `arn:aws:sns:us-east-1:897744507899:station-stream-alerts`.

### 7.2 ✅ Email subscription (needs the owner to click a link)

**Console:** the topic → Create subscription → Protocol **Email** (not Email-JSON, which is raw JSON for programs) → Endpoint `julius@ranklab.org` → Create subscription. Status starts as **Pending confirmation**: AWS emails a link, and nothing is delivered until it's clicked. That opt-in stops anyone from subscribing someone else's inbox.

```bash
# CLI equivalent
aws sns subscribe --topic-arn arn:aws:sns:us-east-1:897744507899:station-stream-alerts \
  --protocol email --notification-endpoint julius@ranklab.org
```

**Check:**
```bash
aws sns list-subscriptions-by-topic --topic-arn arn:aws:sns:us-east-1:897744507899:station-stream-alerts \
  --query 'Subscriptions[].[Protocol,Endpoint,SubscriptionArn]'
# SubscriptionArn shows "PendingConfirmation" until the email link is clicked
```

### 7.3 ✅ CloudWatch alarms (1 in the console, 3 via CLI because they're repetitive)

**What & why:** CloudWatch stores **metrics**, numbers the load balancer reports every minute. An **alarm** watches one metric, flips OK → ALARM when it crosses a threshold, and publishes to the SNS topic (and again on recovery, via `--ok-actions`).

**Design choice:** with **one** task, stopping it makes ECS **deregister** the target first (it shows as *draining*, not *unhealthy*), so an UnHealthyHostCount alarm can stay **silent during a total outage**. The alarm that catches an outage is **HealthyHostCount < 1**.

| Alarm | Metric | Stat / period | Missing data | Catches |
|---|---|---|---|---|
| `no-healthy-targets` | HealthyHostCount (TG + LB) | Minimum, 1 min, < 1, 1 of 1 | **breaching** | Outage: nothing can serve |
| `unhealthy-targets` | UnHealthyHostCount (TG + LB) | Maximum, 1 min, ≥ 1, 2 of 2 | notBreaching | A task failing `/health` |
| `target-5xx` | HTTPCode_Target_5XX_Count (LB) | Sum, 1 min, ≥ 1 | notBreaching | **The app** returned a server error |
| `elb-5xx` | HTTPCode_ELB_5XX_Count (LB) | Sum, 1 min, ≥ 1 | notBreaching | **The load balancer** answered 503 (no healthy target) |

**Missing data is the subtle setting:** 5xx counts publish *nothing* when there are zero errors, so missing = fine (`notBreaching`). HealthyHostCount is always published, so missing = something's wrong (`breaching`). A wrong choice gives an alarm that never fires or never stops.

**Console (the first alarm):** CloudWatch → Alarms → Create alarm →
1. Data source **Metrics**, type **Classic** → Select metric → search `HealthyHostCount` → **ApplicationELB > Per AppELB, per TG Metrics** (not "per AZ": an outage is zero healthy targets *everywhere*) → tick HealthyHostCount (not UnHealthyHostCount, which also matches the search) → Select metric.
2. Statistic **Minimum** (a dip to 0 within the minute shows; Average would smooth it away), Period **1 minute** (ALB metrics are per-minute; 10–30s options are high-resolution and cost more). Threshold **Static**, **Lower** than **1**. Additional configuration: 1 of 1 datapoints, missing data **"Treat missing data as bad (breaching threshold)"**.
3. Actions: Notification **In alarm** → `station-stream-alerts`; **Add notification** → **OK** → same topic (recovery emails tell on-call it's over).
4. Name `station-stream-no-healthy-targets`, description written as a mini runbook (it's included in the email), tag `project=station-stream` → Create alarm.

New alarms start as **INSUFFICIENT_DATA** until their first datapoint. The console also showed **"Some subscriptions are pending confirmation"**: no email goes out until the link is clicked.

**CLI (all four):**
```bash
TOPIC=arn:aws:sns:us-east-1:897744507899:station-stream-alerts
LB=app/station-stream-alb/09b5d527936ae1a4
TG=targetgroup/station-stream-tg/50a7c24c042c2783

aws cloudwatch put-metric-alarm --alarm-name station-stream-no-healthy-targets \
  --namespace AWS/ApplicationELB --metric-name HealthyHostCount \
  --dimensions Name=TargetGroup,Value=$TG Name=LoadBalancer,Value=$LB \
  --statistic Minimum --period 60 --evaluation-periods 1 --threshold 1 \
  --comparison-operator LessThanThreshold --treat-missing-data breaching \
  --alarm-actions $TOPIC --ok-actions $TOPIC

aws cloudwatch put-metric-alarm --alarm-name station-stream-unhealthy-targets \
  --namespace AWS/ApplicationELB --metric-name UnHealthyHostCount \
  --dimensions Name=TargetGroup,Value=$TG Name=LoadBalancer,Value=$LB \
  --statistic Maximum --period 60 --evaluation-periods 2 --datapoints-to-alarm 2 --threshold 1 \
  --comparison-operator GreaterThanOrEqualToThreshold --treat-missing-data notBreaching \
  --alarm-actions $TOPIC --ok-actions $TOPIC

aws cloudwatch put-metric-alarm --alarm-name station-stream-target-5xx \
  --namespace AWS/ApplicationELB --metric-name HTTPCode_Target_5XX_Count \
  --dimensions Name=LoadBalancer,Value=$LB --statistic Sum --period 60 --evaluation-periods 1 \
  --threshold 1 --comparison-operator GreaterThanOrEqualToThreshold --treat-missing-data notBreaching \
  --alarm-actions $TOPIC --ok-actions $TOPIC

aws cloudwatch put-metric-alarm --alarm-name station-stream-elb-5xx \
  --namespace AWS/ApplicationELB --metric-name HTTPCode_ELB_5XX_Count \
  --dimensions Name=LoadBalancer,Value=$LB --statistic Sum --period 60 --evaluation-periods 1 \
  --threshold 1 --comparison-operator GreaterThanOrEqualToThreshold --treat-missing-data notBreaching \
  --alarm-actions $TOPIC --ok-actions $TOPIC
```

**Check:**
```bash
aws cloudwatch describe-alarms --alarm-name-prefix station-stream \
  --query 'MetricAlarms[].[AlarmName,StateValue,MetricName,Statistic,Threshold,TreatMissingData]' --output table
```

### 7.4 ✅ Autoscaling: 1–2 tasks, target 60% CPU (done in the console)

**What & why:** Application Auto Scaling changes the service's task count. **Target tracking** works like a thermostat: set 60% average CPU, and it adds a task above that and removes one well below it. **Max 2** is a cost cap (the console defaulted to **10**). Scaling is free; a second task bills (~$0.008/hr) only while it runs.

**Console (what was clicked):** ECS → station-stream → api → **Service auto scaling** tab (scroll the tab bar right) →
1. **Set the number of tasks** → tick "Use service auto scaling" → Min **1**, Max **2** (changed from 10) → Save.
2. **Create scaling policy** → **Target tracking** (vs Step scaling: fixed rules per threshold; Predictive: learns daily patterns, handy for prime-time peaks) → name `cpu60` → metric **ECSServiceAverageCPUUtilization** → target **60** → Additional settings left at defaults (300s scale-out and scale-in cooldowns, so the count doesn't flap) → Create.

AWS created the service-linked role `AWSServiceRoleForApplicationAutoScaling_ECSService` automatically (allowed by `iam:CreateServiceLinkedRole` in our scoped policy).

**CLI equivalent:**
```bash
aws application-autoscaling register-scalable-target --service-namespace ecs \
  --resource-id service/station-stream/api --scalable-dimension ecs:service:DesiredCount \
  --min-capacity 1 --max-capacity 2
aws application-autoscaling put-scaling-policy --service-namespace ecs \
  --resource-id service/station-stream/api --scalable-dimension ecs:service:DesiredCount \
  --policy-name cpu60 --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration \
  '{"TargetValue":60,"PredefinedMetricSpecification":{"PredefinedMetricType":"ECSServiceAverageCPUUtilization"}}'
```

**Check, and a design detail:** target tracking quietly creates **two CloudWatch alarms of its own**:
```bash
aws application-autoscaling describe-scaling-policies --service-namespace ecs --resource-id service/station-stream/api
aws cloudwatch describe-alarms --alarm-name-prefix TargetTracking \
  --query 'MetricAlarms[].[AlarmName,ComparisonOperator,Threshold,EvaluationPeriods]' --output table
```
| Auto-created alarm | Rule | Effect |
|---|---|---|
| `…-AlarmHigh-…` | CPU > 60% for **3** minutes | scale **out fast** |
| `…-AlarmLow-…` | CPU < 54% for **15** minutes | scale **in slowly** |

Asymmetric on purpose: too little capacity hurts users, an extra task for a few minutes costs pennies. The 54% (not 60%) low threshold stops the count bouncing between 1 and 2. Don't edit or delete these alarms by hand; the policy owns them.

### 7.5 ✅ Chaos test: stop the only task on purpose

**Setup:** confirm the email subscription (its ARN changes from `PendingConfirmation` to a real ID), then send one request per second to the public URL and log the HTTP code:
```bash
while true; do echo "$(date +%T) $(curl -s -o /dev/null -m 3 -w '%{http_code}' http://station-stream-alb-565835838.us-east-1.elb.amazonaws.com/health)"; sleep 1; done
```

**Console (what was clicked):** ECS → station-stream → api → **Tasks** tab → tick the task → **Stop** ▾ → **Stop selected** → dialog warns *"tasks started by a service should be stopped by updating the service"* (i.e. the service will just replace it) → Stop. Task **Health status** showed "Unknown": ECS ignores the Dockerfile `HEALTHCHECK` unless the task definition repeats it; health here comes from the load balancer.

```bash
# CLI equivalent
aws ecs stop-task --cluster station-stream --task <task-arn> --reason "chaos test"
```

**Prediction:** all 4 alarms fire. **Result: only `elb-5xx` fired.**

**Timeline:**
```
20:47:35  ECS deregisters the old task (draining) and, 1 second later, starts a replacement
20:47:37  first 503 seen by viewers
20:48:04  new task registered in the target group
20:48:06  last 503: viewer-facing outage ≈ 30 seconds, 24 failed requests
20:48:13  service "has reached a steady state"
20:50:17  elb-5xx  OK → ALARM   (≈2.5 min after the first error: metric publishing delay)
20:57:17  elb-5xx  ALARM → OK   (≈9 min after the last error: CloudWatch looks back over several datapoints)
```

**Why each alarm did (or didn't) fire, from the raw metrics:**
```bash
aws cloudwatch get-metric-statistics --namespace AWS/ApplicationELB --metric-name HealthyHostCount \
  --dimensions Name=TargetGroup,Value=$TG Name=LoadBalancer,Value=$LB \
  --start-time <t-12m> --end-time <now> --period 60 --statistics Minimum
```
| Alarm | Fired? | Why |
|---|---|---|
| `elb-5xx` | ✅ yes | HTTPCode_ELB_5XX_Count = **18 + 6 = 24**, exactly the 24 503s in the curl log. The load balancer answered 503 itself: nobody to send to. |
| `target-5xx` | no | The app never returned an error; it simply wasn't there. Target 5xx = no data. |
| `unhealthy-targets` | no | ECS *deregistered* the task (draining) before stopping it; it never failed a health check. UnHealthyHostCount stayed 0. |
| `no-healthy-targets` | no | The 20:47 datapoint is **missing entirely**: the ALB publishes nothing while no targets are registered. "Treat missing as breaching" only applies when **every** datapoint in CloudWatch's look-back range is missing; the 20:46 and 20:48 values (1.0) were present, so a 30-second gap was skipped. A multi-minute outage would leave all of them missing and fire it. |

**Lesson:** the viewer-facing signal (`elb-5xx`) caught a 30-second blip that the capacity signals missed. Alert on what users experience, and use capacity alarms for longer outages. Also: alarms lag. Detection took ~2.5 min, longer than the outage itself.

**What would remove the blip:** `minimumHealthyPercent=100` only protects **deployments** (start new before stopping old). It does nothing for a crash or a manual stop. The only protection there is **2+ tasks in different zones**, so the load balancer always has someone to send to. One task is a single point of failure; we accept that here to save money.

**Check:**
```bash
aws cloudwatch describe-alarm-history --alarm-name station-stream-elb-5xx --history-item-type StateUpdate \
  --query 'AlarmHistoryItems[].[Timestamp,HistorySummary]' --output text
aws ecs describe-services --cluster station-stream --services api --query 'services[0].events[0:6].[createdAt,message]' --output text
```

---

## Phase 8 ✅: GitHub Actions deploys with OIDC (no stored AWS keys)

**What & why:** every push to `main` builds the image, pushes it to ECR, and rolls it out to ECS, with **no AWS keys stored in GitHub**. OIDC (OpenID Connect) works like a signed ID card: GitHub gives the workflow a short-lived token saying "repo `ideaguy3d/station_stream`, branch `main`"; AWS checks the signature and swaps it for ~1-hour credentials.

### 8.1 ✅ GitHub as an identity provider (done in the console)

Done once per AWS account; every repo's role points at it. On its own it grants nothing.

**Console (what was clicked):** IAM → Identity providers → Add provider → **OpenID Connect** (not SAML, the older XML standard used by Okta/AD) → Provider URL `https://token.actions.githubusercontent.com` → Audience `sts.amazonaws.com` (the token is meant for AWS's token service) → tag `project=station-stream` → Add provider. Banner: *"You must assign an IAM role to start using this provider."*

```bash
# CLI equivalent
aws iam create-open-id-connect-provider --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com --tags Key=project,Value=station-stream
```

**Check:**
```bash
aws iam get-open-id-connect-provider \
  --open-id-connect-provider-arn arn:aws:iam::897744507899:oidc-provider/token.actions.githubusercontent.com
```
The console fetched a thumbprint (a fingerprint of GitHub's TLS certificate). For GitHub, AWS now validates against trusted certificate authorities instead, so a rotated cert won't break deploys.

### 8.2 ✅ Deploy role that only `main` of this repo can use (done in the console)

**What & why:** the role the workflow takes on. Two halves:
- **Trust** ([infra/iam/github-oidc-trust.json](../infra/iam/github-oidc-trust.json)), *who*: tokens from GitHub, meant for AWS (`aud = sts.amazonaws.com`), **and** from `repo:ideaguy3d/station_stream:ref:refs/heads/main` (`sub`). Forks, PRs and other branches are refused. **Forgetting the `sub` check is the classic OIDC mistake: without it, any GitHub repo in the world could use your role.**
- **Permissions** ([infra/iam/github-deploy-policy.json](../infra/iam/github-deploy-policy.json)), *what*: ECR login; push only to `repository/station-stream`; register task definitions; update only `service/station-stream/api`; `iam:PassRole` only on `station-stream-task-exec` and only to `ecs-tasks.amazonaws.com`. No deletes.

**Console (what was clicked):** IAM → Roles → Create role →
1. Trusted entity **Web identity** (others: AWS service, AWS account, SAML, Custom trust policy) → Identity provider `token.actions.githubusercontent.com` → Audience `sts.amazonaws.com` → GitHub organization `ideaguy3d` → repository `station_stream` → branch `main`. **Repository and branch are "optional" and default to `*`**, which would let any repo/branch in the org deploy. Always fill them in.
2. Add permissions → **Create inline policy** → JSON. Pasting didn't work (the browser pane doesn't share the Mac clipboard), so the JSON was typed and then validated by reading the editor's contents (valid, 5 statements). Red herring below the editor: `not authorized to perform access-analyzer:ValidatePolicy`, the live policy linter needs a permission our user lacks; the policy itself is fine.
3. Name `station-stream-github-deploy`, description, inline policy name `station-stream-github-deploy-policy`, tag `project=station-stream` → Create role.

The wizard's generated trust policy uses `StringLike` and lists the `sub` value twice (harmless). With no `*` in it, `StringLike` behaves as an exact match.

**CLI equivalent:**
```bash
aws iam create-role --role-name station-stream-github-deploy \
  --assume-role-policy-document file://infra/iam/github-oidc-trust.json \
  --tags Key=project,Value=station-stream
aws iam put-role-policy --role-name station-stream-github-deploy \
  --policy-name station-stream-github-deploy-policy \
  --policy-document file://infra/iam/github-deploy-policy.json
```

**Check:**
```bash
aws iam get-role --role-name station-stream-github-deploy \
  --query 'Role.[MaxSessionDuration, AssumeRolePolicyDocument.Statement[0].Condition]'   # 3600s = credentials last 1 hour max
aws iam get-role-policy --role-name station-stream-github-deploy \
  --policy-name station-stream-github-deploy-policy --query 'PolicyDocument.Statement[].Sid'
```

### 8.3 ❌→✅ The workflow, and the `sub` claim that didn't match

**What & why:** [.github/workflows/deploy.yml](../.github/workflows/deploy.yml) runs on every push to `main` (doc-only changes skipped):

| Step | What it does |
|---|---|
| `permissions: id-token: write` | Lets the job request an OIDC token from GitHub |
| `concurrency: deploy-production` | Never two deploys at once; a newer one queues instead of killing a rollout mid-way |
| `runs-on: ubuntu-24.04-arm` | Native ARM build (free for public repos), same chip family as Fargate ARM64, no emulation |
| configure-aws-credentials@v6 | Swaps the OIDC token for ~1-hour credentials via `role-to-assume`; session name `gha-<run id>` shows up in CloudTrail |
| amazon-ecr-login@v2 | Docker login to ECR |
| Build and push | Tag = first 7 chars of the commit. **Skips the build if the tag already exists**: tags are immutable, so a re-run would otherwise fail on push |
| render-task-definition@v1 | Writes the new image and `APP_VERSION` into `infra/ecs/taskdef.json` |
| deploy-task-definition@v2 | Registers a new revision, updates the service, **waits for stability** (fails the job if the rollout fails) |
| Smoke test | Polls `/health` until the live `version` equals the commit, so "green" means *users* have the new code |

Actions are pinned to major versions (`@v6`). For stronger supply-chain security you'd pin each to a full commit SHA.

**❌ First run failed at the credentials step:**
```
Could not assume role with OIDC: Not authorized to perform sts:AssumeRoleWithWebIdentity
```
**Diagnosis:** this means a trust-policy condition didn't match, usually `sub`. Compare what GitHub *sends* with what AWS *expects*:
```bash
gh api repos/ideaguy3d/station_stream/actions/oidc/customization/sub
# {"use_default":true,"use_immutable_subject":true,
#  "sub_claim_prefix":"repo:ideaguy3d@14084686/station_stream@1409232207"}
```
| | `sub` |
|---|---|
| Trust policy expected (what the console wizard builds) | `repo:ideaguy3d/station_stream:ref:refs/heads/main` |
| GitHub actually sent | `repo:ideaguy3d@14084686/station_stream@1409232207:ref:refs/heads/main` |

The repo uses GitHub's **immutable subject** format, which adds the numeric owner and repo IDs. Why it exists: with name-only subjects, if this repo were deleted or renamed, someone could create a new repo with the **same name** and inherit the AWS trust. IDs are never reused.

**✅ Fix (console):** IAM → Roles → station-stream-github-deploy → **Trust relationships** → Edit trust policy → replace with [infra/iam/github-oidc-trust.json](../infra/iam/github-oidc-trust.json) (immutable `sub`, `StringEquals`) → Update policy. Then `gh run rerun 37726329961` (same commit, so it tests only the fix).
```bash
# CLI equivalent
aws iam update-assume-role-policy --role-name station-stream-github-deploy \
  --policy-document file://infra/iam/github-oidc-trust.json
```

**Result:** all 8 steps green in 3m26s. Live `/health` → `"version":"be5ccf1"`; service on `station-stream:3`; image `be5ccf1` scanned clean; smoke test passed on attempt 1; **0 secrets stored in GitHub**.

**Second deploy, triggered by a normal `git push` (commit `0c5fffd`):** green in 7m28s, live version `0c5fffd`. Why slower: build 9s, but "Deploy to ECS" took **428s vs 178s**. ECS itself reached steady state in ~2.5 min (21:19:05 → 21:21:27); the step ran 21:18:53 → 21:26:01. The action's "wait until stable" check polls with **exponential backoff** (15s, 30s, 60s … up to 2 min between polls), so it noticed ~4.5 min late. The deploy was fast; *knowing* it was done was slow. The log line `AWS_ACCESS_KEY_ID: ***` is the temporary OIDC credential, masked by GitHub, not a stored key.

**Check:**
```bash
gh run list --repo ideaguy3d/station_stream --limit 3
gh secret list --repo ideaguy3d/station_stream            # empty: no AWS keys anywhere in GitHub
curl -s http://station-stream-alb-565835838.us-east-1.elb.amazonaws.com/health   # version = latest commit
aws ecs describe-services --cluster station-stream --services api --query 'services[0].taskDefinition'
```

---

## Phase 9 ✅: Terraform builds app 2, a separate copy (`station-stream-tf`)

**What & why:** Terraform reads `.tf` files that describe the *end state* ("there should be a load balancer like this"), compares them with what exists, and creates/changes/deletes the difference. Its **state file** (`terraform/terraform.tfstate`, git-ignored, local) is its memory of which real resources it owns. App 1 is untouched: it isn't in this state, so Terraform can't see or change it.

All code is in [terraform/](../terraform/). Every resource name starts with `station-stream-tf-`, which our IAM limits allow, and `default_tags` stamps `project`, `app` and `managed=terraform` on everything.

### 9.1 Console step → Terraform file

| What you watched in the console | Terraform | File |
|---|---|---|
| 5.1 Default VPC, subnets 1a/1b | `data "aws_vpc"`, `data "aws_subnet"` (look up, don't create) | [network.tf](../terraform/network.tf) |
| 5.2 Two chained security groups | `aws_security_group` ×2, `aws_vpc_security_group_ingress_rule` (task rule uses `referenced_security_group_id`) + **egress rules**, which the console adds silently | network.tf |
| 4.1–4.2 ECR repo, immutable, scan, keep 10 | `aws_ecr_repository`, `aws_ecr_lifecycle_policy` | [ecr.tf](../terraform/ecr.tf) |
| 5.3 Task execution role | `data "aws_iam_policy_document"` (trust with confused-deputy conditions), `aws_iam_role`, `aws_iam_role_policy_attachment` | [iam.tf](../terraform/iam.tf) |
| 5.6–5.8 Load balancer, target group, listener | `aws_lb`, `aws_lb_target_group` (`deregistration_delay = 30`), `aws_lb_listener` | [alb.tf](../terraform/alb.tf) |
| 5.4, 5.5, 5.9, 5.10 Logs, cluster, task definition, service | `aws_cloudwatch_log_group`, `aws_ecs_cluster`, `aws_ecs_task_definition`, `aws_ecs_service` (circuit breaker, `ignore_changes = [desired_count]` so autoscaling isn't undone) | [ecs.tf](../terraform/ecs.tf) |
| 6.1–6.2 Private bucket + upload with content types | `aws_s3_bucket`, public access block, ownership controls, **`aws_s3_object` with `for_each` over `fileset()`** (141 files, Content-Type/Cache-Control by extension) | [video.tf](../terraform/video.tf) |
| 6.3 CloudFront + OAC + bucket policy | `aws_cloudfront_origin_access_control`, `data` lookups of the managed cache/CORS policies by name, `aws_cloudfront_distribution`, `aws_s3_bucket_policy` | video.tf |
| 6.4 New task definition revision with the CloudFront URL | **Not needed**: `VIDEO_BASE_URL = "https://${aws_cloudfront_distribution.video.domain_name}"` wires it automatically | ecs.tf |
| 7.1–7.4 SNS, email, 4 alarms, autoscaling | `aws_sns_topic`, `aws_sns_topic_subscription`, **one `aws_cloudwatch_metric_alarm` with `for_each` over a map of 4**, `aws_appautoscaling_target` + `_policy` | [monitoring.tf](../terraform/monitoring.tf) |

Deliberate difference from app 1: CloudFront `price_class = "PriceClass_100"` (what was planned; app 1's console defaulted to All).

### 9.2 Commands, in order

```bash
cd terraform
export AWS_PROFILE=station-stream AWS_REGION=us-east-1

terraform init        # download the AWS provider (6.68.0), write .terraform.lock.hcl (commit this)
terraform fmt         # format the files
terraform validate    # syntax/type check, no AWS calls
terraform plan        # → Plan: 172 to add, 0 to change, 0 to destroy   (141 are video files)
```

**Chicken-and-egg:** the ECS service can't start until its image is in the *new* repo, which Terraform creates. So bootstrap in three steps:
```bash
# 1. Create only the repo. -target is for bootstrapping/emergencies only: it skips the full dependency check.
terraform apply -target=aws_ecr_repository.app -target=aws_ecr_lifecycle_policy.keep_10

# 2. Copy app 1's image (same code, built by GitHub Actions) into it
REG=897744507899.dkr.ecr.us-east-1.amazonaws.com
aws ecr get-login-password | docker login -u AWS --password-stdin $REG
docker pull --platform linux/arm64 $REG/station-stream:0c5fffd
docker tag $REG/station-stream:0c5fffd $REG/station-stream-tf:0c5fffd
docker push $REG/station-stream-tf:0c5fffd

# 3. Everything else. Save the plan and apply exactly that file, so nothing changes between review and apply.
terraform plan -out=tfplan
terraform apply tfplan
```

### 9.3 ❌→✅ Autoscaling tag permissions (and why a workaround failed)

**Result of the first full apply:** 170 of 172 created; app 2 healthy at http://station-stream-tf-alb-862429135.us-east-1.elb.amazonaws.com/?station=north, video from its own CloudFront `d990usezj0kzv.cloudfront.net`. The service started last (uptime looked short) because the task definition *references* the CloudFront domain, so Terraform waited ~2m43s for CloudFront first. Terraform derives that order from references: its **dependency graph**.

**❌ Error 1:**
```
creating Application AutoScaling Target (service/station-stream-tf/api): AccessDeniedException:
... not authorized to perform: application-autoscaling:TagResource on resource: ...:scalable-target/*
```
**Diagnosis:** `default_tags` makes Terraform tag *every* resource. In the console (app 1) the scalable target got no tags, so this permission was never needed. Our autoscaling rights come from `AmazonECS_FullAccess`, which lacks `TagResource`. Same pattern as SNS in 7.1.

**Workaround tried:** a second provider block with `alias = "untagged"` (no default_tags) used only by that resource. Provider aliases are how one config deploys to two regions or accounts.

**❌ Error 2:** `not authorized to perform: application-autoscaling:ListTagsForResource`. The AWS provider **always reads tags back** after creating a resource, tagged or not, so no tag-free trick can avoid it. The target *was* created and recorded in state; the policy was not.

**Fix (owner, as root):** add to [infra/iam/builder-iam-scoped.json](../infra/iam/builder-iam-scoped.json):
```json
{ "Sid": "TagAutoScalingTargets", "Effect": "Allow",
  "Action": ["application-autoscaling:TagResource","application-autoscaling:UntagResource",
             "application-autoscaling:ListTagsForResource"],
  "Resource": "arn:aws:application-autoscaling:us-east-1:897744507899:scalable-target/*" }
```
IAM → User groups → station-stream-builders → Permissions → `station-stream-iam-scoped` → Edit → JSON → paste → Next → Save. Then remove the alias and `terraform apply` again.

**Lesson:** Terraform touches more APIs than the console does for the "same" thing (tagging, reading tags back, explicit egress rules). Least-privilege policies written by watching console clicks will have gaps; the error message names the exact action to add.

### 9.4 ✅ Finish and verify

```bash
terraform plan -out=tfplan   # → aws_appautoscaling_target.api is tainted, so must be replaced; Plan: 2 to add, 1 to destroy
terraform apply tfplan
```
**Tainted:** the target was created in AWS but a later step (reading its tags) failed, so Terraform no longer trusts it and replaces it on the next apply. That's how a half-finished apply heals itself.

**Drift check, the proof that code = reality:**
```bash
terraform plan -detailed-exitcode   # exit 0 = "No changes"; 2 = something differs; 1 = error
```

| Check | Result |
|---|---|
| Drift check | exit **0**, No changes |
| App 2 `/health` | `ok`, version `0c5fffd`, 1 healthy target |
| Video | plays from `d990usezj0kzv.cloudfront.net` |
| Alarms | 4 × OK; email subscription confirmed (Terraform can create it, not click the link) |
| Autoscaling tags | `project`, `app`, `managed=terraform` |
| App 1 | untouched, still healthy |

**Not yet allowed:** `tag:GetResources` (the "list everything by tag" search). Teardown checks will need it or another method.

**Destroying app 2 later** is one command (bucket and repo have `force_destroy`/`force_delete` so they empty themselves):
```bash
cd terraform && terraform destroy
```

---

## Phase G1: HTTPS + CORS so the GCP-hosted UI can call app 2 (Terraform)

Part of the GCP plan ([HANDOFF.md](HANDOFF.md) section 4, GCP log in [gcp-breadcrumbs.md](gcp-breadcrumbs.md)). The web UI moves to Firebase Hosting at `https://station-stream-2026.web.app`, which is HTTPS-only. App 2's API is plain HTTP on the ALB, so two browser rules would block the calls:

- **Mixed content:** an HTTPS page may not call an `http://` API. Fix: CloudFront in front of the ALB gives it free `https://*.cloudfront.net`.
- **CORS (Cross-Origin Resource Sharing):** a page on one origin (scheme + host + port) can't read responses from another origin unless the server says so with `Access-Control-Allow-Origin`. Fix: CORS middleware in the API.

Done in **Terraform, not the console**: app 2 is owned by Terraform, so console edits would be **drift** that the next `apply` reverts. Starting point: `terraform plan` → *No changes* (no drift).

### G1.1 ✅ CORS in the API (code, both apps)

**What & why:** the `cors` Express middleware answers the browser's **preflight** (an automatic `OPTIONS` request sent before a cross-origin `POST` with a JSON body) and adds `Access-Control-Allow-Origin` only for origins listed in the `CORS_ORIGINS` env var. Empty (app 1) = same-origin only, which is all the built-in player needs. `maxAge: 600` lets browsers skip the preflight for 10 minutes. CORS is enforced **by the browser**, not the server: `curl` ignores it, so it's not authentication; it only decides which web pages may read responses.

```js
app.use('/graphql', cors({ origin: CORS_ORIGINS, methods: ['GET', 'POST'], maxAge: 600 }), express.json(), expressMiddleware(apollo));
```

**Check (local, before shipping):**
```bash
PORT=4100 CORS_ORIGINS=https://station-stream-2026.web.app node src/server.js &
# allowed origin → 204 + Access-Control-Allow-Origin: https://station-stream-2026.web.app
curl -si -X OPTIONS localhost:4100/graphql -H 'Origin: https://station-stream-2026.web.app' -H 'Access-Control-Request-Method: POST'
# other origin → 204 but NO Allow-Origin header, so a browser blocks it
curl -si -X OPTIONS localhost:4100/graphql -H 'Origin: https://evil.example' -H 'Access-Control-Request-Method: POST'
```

Shipped as commit `461037e`. The push ran the GitHub Actions deploy, so app 1 got the same code (no `CORS_ORIGINS`, behavior unchanged).

### G1.2 ✅ CloudFront in front of app 2's ALB

**What & why:** a second distribution ([api_cdn.tf](../terraform/api_cdn.tf)), origin = the ALB over **HTTP** (`origin_protocol_policy = "http-only"`: the ALB has no certificate, HTTPS ends at CloudFront). Two managed policies, looked up by name:

- **`Managed-CachingDisabled`**: GraphQL answers are per-request `POST`s. Caching would serve one user's answer to another.
- **`Managed-AllViewerExceptHostHeader`** (origin request policy): forwards every viewer header (including `Origin` and `Access-Control-Request-*`, which CORS needs) and query strings, except `Host`, which CloudFront sets to the ALB's own name.

`allowed_methods` must be the full 7 (CloudFront only offers 2, 3 or 7), because the API needs `POST` and `OPTIONS`. No hourly cost: CloudFront bills per request/GB, inside the free tier at our traffic.

Also: `CORS_ORIGINS` in the task definition from `var.cors_origins` (`https://station-stream-2026.web.app`, `https://station-stream-2026.firebaseapp.com`), and a new output `api_url`.

```bash
cd terraform && export AWS_PROFILE=station-stream AWS_REGION=us-east-1
terraform fmt && terraform validate
terraform plan
# Plan: 2 to add, 1 to change, 1 to destroy
#  + aws_cloudfront_distribution.api
#  ~ aws_ecs_service.app             (points at the new revision → rolling deploy)
#  -/+ aws_ecs_task_definition.app   ("destroy" = retiring revision 1; task defs are never edited, only replaced)
```

**Console (what this would be by hand):** CloudFront → Create distribution → Origin: pick the ALB (`station-stream-tf-alb-…`), Protocol **HTTP only** → Default cache behavior: Viewer protocol **Redirect HTTP to HTTPS**, Allowed methods **GET, HEAD, OPTIONS, PUT, POST, PATCH, DELETE**, Cache policy **CachingDisabled**, Origin request policy **AllViewerExceptHostHeader** → Price class: North America and Europe → Create. Then ECS → Task definitions → `station-stream-tf` → Create new revision → add env `CORS_ORIGINS` → Update service.

### G1.3 ✅ Ship the CORS image to app 2 and apply

**What & why:** app 2 runs images from its own repo `station-stream-tf`, pinned by `var.image_tag`. Copy the image GitHub Actions built for `461037e` (same pattern as 9.2), then apply the plan with the new tag, so the env var and the code that reads it arrive together.

```bash
REG=897744507899.dkr.ecr.us-east-1.amazonaws.com
aws ecr get-login-password | docker login -u AWS --password-stdin $REG
docker pull --platform linux/arm64 $REG/station-stream:461037e
docker tag $REG/station-stream:461037e $REG/station-stream-tf:461037e
docker push $REG/station-stream-tf:461037e
# image_tag default bumped to 461037e in variables.tf, so a plain apply keeps it
terraform plan -out=tfplan && terraform apply tfplan
```

**Check:**
```bash
API=$(terraform output -raw api_url)
curl -s $API/health                                   # {"status":"ok","version":"461037e",...}
curl -si -X OPTIONS $API/graphql -H 'Origin: https://station-stream-2026.web.app' \
  -H 'Access-Control-Request-Method: POST' | grep -i access-control-allow-origin
```

**Result:** `Apply complete! Resources: 2 added, 1 changed, 1 destroyed` in 2m56s, almost all of it CloudFront propagating to edge locations. **API URL: https://d1436kyrcdypmk.cloudfront.net** (distribution `E7BB4SHJWN2O6`), task definition `station-stream-tf:2`, image `461037e`.

- `/health` over HTTPS → `{"status":"ok","version":"461037e",...}`
- Preflight from `https://station-stream-2026.web.app` → `204`, `access-control-allow-origin` set, methods `GET,POST`
- Real query → `200` + `access-control-allow-origin`; `x-cache: Miss from cloudfront` every time (caching off, as intended)
- `http://` → `301` to `https://`
- The old ALB URL still answers on HTTP (CloudFront was added in front, nothing removed)
- `terraform plan` afterwards → *No changes*

**Gotcha (again):** `aws ecs wait services-stable` returned in 1.5 s while the rollout said `IN_PROGRESS`. The waiter only compares running vs desired counts, which already matched while the old task drained. Poll `deployments[0].rolloutState` until `COMPLETED` instead:
```bash
aws ecs describe-services --cluster station-stream-tf --services api \
  --query 'services[0].{rollout:deployments[0].rolloutState,deployments:length(deployments),taskDef:taskDefinition}'
```

---

## Phase L1 🔜: Aurora PostgreSQL Serverless v2 holds the catalog (Terraform, app 2)

> Plan: [PLAN-L1-L2.md](PLAN-L1-L2.md). Terraform file: [terraform/database.tf](../terraform/database.tf). Cost: Aurora Serverless v2 bills per ACU-hour (about $0.12 in us-east-1 *(verify)*); **$0 compute while auto-paused**, up to ~$0.48/h at the 4-ACU cap. Two secrets: $0.40/month each.

### L1.0 ❌ What the IAM user can't do yet (the permissions check)

**What & why:** before writing Terraform for a new service, find out what `station-stream-dev` is allowed to do with it. The user only has the policies listed in Phase 0 (ECS, ECR, ELB, VPC, S3, CloudFront, CloudWatch full access + our scoped IAM/SNS statements), so RDS and Secrets Manager were never granted.

**Check (read-only calls, run as `station-stream-dev`):**
```bash
export AWS_PROFILE=station-stream AWS_REGION=us-east-1
aws rds describe-db-clusters
aws secretsmanager list-secrets
```
**Real errors:**
```
AccessDenied when calling the DescribeDBClusters operation: User: arn:aws:iam::897744507899:user/station-stream-dev
is not authorized to perform: rds:DescribeDBClusters on resource: arn:aws:rds:us-east-1:897744507899:cluster:*
because no identity-based policy allows the rds:DescribeDBClusters action

AccessDeniedException when calling the ListSecrets operation: ... is not authorized to perform:
secretsmanager:ListSecrets because no identity-based policy allows the secretsmanager:ListSecrets action
```
**Diagnosis:** "no identity-based policy allows" means an *implicit deny*: nothing says yes, so the answer is no. It is not an explicit deny and not a service-control policy. The fix is to add an Allow, not to remove a Deny.

**Fix (owner's clicks; permission changes are blocked for Claude):** three new statements in [infra/iam/builder-iam-scoped.json](../infra/iam/builder-iam-scoped.json), same pattern as the SNS one:
- `RdsReadOnly`: `rds:Describe*` and `rds:ListTagsForResource` on `*` (Describe calls can't be scoped well, and they change nothing).
- `ManageStationStreamAurora`: create/modify/delete for clusters, instances and subnet groups, only on resources named `station-stream-*`.
- `ManageStationStreamSecrets`: Secrets Manager actions only on secrets named `station-stream-*`.

Console: IAM → User groups → `station-stream-builders` → Permissions → `station-stream-iam-scoped` → Edit → JSON → paste the file → Next → Save changes.
```bash
# the CLI equivalent (what the console does)
aws iam put-group-policy --group-name station-stream-builders --policy-name station-stream-iam-scoped \
  --policy-document file://infra/iam/builder-iam-scoped.json
```
**Check:** `aws rds describe-db-clusters` returns `{"DBClusters": []}` instead of AccessDenied.

### L1.1 ❌ Network, cluster, instance and secret (`terraform/database.tf`): blocked by the Free plan

**What & why:**
- **DB subnet group**: the list of subnets (in 2+ AZs) RDS may place the cluster in.
- **Security group `station-stream-tf-db`**: port 5432 allowed *only from the task security group* (a group reference, not an IP range), so only API tasks can talk to the database.
- **Aurora cluster** (`aurora-postgresql`, `engine_mode = provisioned`, scaling 0–4 ACU, auto-pause after 300 s) with `manage_master_user_password = true`: RDS creates the admin password and keeps it in Secrets Manager, so it never touches our code or chat. Encrypted storage, Data API on (console Query Editor), not publicly accessible.
- **One writer instance** of class `db.serverless`. A second instance in another AZ would be the reader that gives fast failover; skipped to keep the bill small.
- **`random_password` + secret `station-stream-tf/db/api-reader`**: the password for the API's read-only database user.

**CLI:** `cd terraform && terraform plan -out=tfplan && terraform apply tfplan` (plan before IAM grant: *8 to add, 0 to change, 0 to destroy*).
**Console:** RDS → Create database → Aurora (PostgreSQL-compatible) → Serverless v2 → capacity range 0–4 ACU → Credentials management: *Managed in AWS Secrets Manager* → Connectivity: Public access *No*, existing VPC security group.
**Check:**
```bash
aws rds describe-db-clusters --db-cluster-identifier station-stream-tf-db \
  --query 'DBClusters[0].{status:Status,engine:EngineVersion,scaling:ServerlessV2ScalingConfiguration,http:HttpEndpointEnabled,encrypted:StorageEncrypted}'
```

**What happened on `terraform apply` (after the IAM grant worked: no AccessDenied):** the subnet group, DB security group + ingress rule, `random_password` and the secret were created (6 of 8, all free except the secret at $0.40/month). The cluster failed:
```
Error: creating RDS Cluster (station-stream-tf-db): operation error RDS: CreateDBCluster, https response error
StatusCode: 400, api error FreeTierRestrictionError: To use Aurora clusters with free plan accounts you need to set
WithExpressConfiguration.  To remove all limitations, upgrade your account plan.
```
**Diagnosis:** not IAM (the policy worked) and not a Terraform mistake: it is an **account-plan restriction**. On an AWS *Free plan* account, Aurora can only be created with *express configuration*, where AWS chooses every setting itself. Checked three ways: `aws rds create-db-cluster help` (the flag exists and takes only an identifier + engine), `terraform providers schema` (provider 6.68.0 has **no** attribute for it, so Terraform cannot create one), and AWS docs: express clusters (a) cannot be placed in a VPC, so no private subnets or security-group rules, (b) are reached through an always-on **internet access gateway**, (c) allow **IAM authentication only**: no Secrets Manager password, no `api_reader` password login, (d) can't pick an engine version, (e) cap at 4 ACU / 1 GB on the free tier. That would replace the planned design (private DB, SG-to-SG rule, Secrets Manager injection) with a different one.
**Options on the table:** (A) upgrade the account to a Paid plan (one-way; unused credits carry over), then apply unchanged; (B) express cluster with IAM auth, a new design outside Terraform; (C) skip creating Aurora, keep the tested code, go to L2 on the JSON-backed API.
**Check the plan type:** console → Billing and Cost Management → account plan banner ("Upgrade plan").

**Second and third errors after the upgrade (each fixed in turn):**

1. `InvalidParameterValue: DatabaseName catalog cannot be used. It is a reserved word for this engine.` `catalog` collides with PostgreSQL's `pg_catalog` system schema. Renamed the initial database to `stationstream` (`var.db_name`).
2. `KMSKeyNotAccessibleFault: The specified KMS key [null] either doesn't exist, isn't enabled, or isn't accessible by the current user.` The `[null]` is misleading: no custom key was named, so RDS used the AWS-managed defaults. **Diagnosis** with read-only calls as `station-stream-dev`:
```bash
aws kms describe-key --key-id alias/aws/rds
aws kms describe-key --key-id alias/aws/secretsmanager
# AccessDeniedException ... not authorized to perform: kms:DescribeKey on resource: arn:aws:kms:us-east-1:897744507899:key/106c44e9-...
# because no identity-based policy allows the kms:DescribeKey action
```
Both keys exist (their ARNs are in the errors); the *caller* may not use them. Aurora encrypts storage with `aws/rds`, and the RDS-managed admin password is stored with `aws/secretsmanager`. **Fix (owner's clicks):** two statements in [builder-iam-scoped.json](../infra/iam/builder-iam-scoped.json): `kms:DescribeKey` on exactly those two key ARNs, and `kms:CreateGrant` on them only when the call comes *via* `rds` or `secretsmanager` (a grant is how a service gets to use your key on your behalf). Nothing else on KMS: no `Decrypt`, no custom keys.

3. After the KMS grant worked (`describe-key` now returns `Enabled`), the next gate, as predicted: `AccessDenied: The user isn't authorized to create a secret in AWS Secrets Manager. Either grant the user permission to create a secret, or create the secret with a different user that has permission.` **Diagnosis:** with `manage_master_user_password = true`, RDS creates the admin-password secret **using the caller's permissions**, and names it `rds!cluster-<uuid>`, which does not match our `station-stream-*` secrets statement. **Fix (owner's clicks):** statement `CreateRdsManagedMasterSecret`: only `secretsmanager:CreateSecret` + `TagResource`, only on `secret:rds!cluster-*`. No read access to that secret for the dev user: the password stays unreadable to us.

4. ❌ **Same error after the owner saved the policy.** Diagnosed without guessing:
   - **AWS docs** (Aurora User Guide, "Permissions required for Secrets Manager integration") list exactly `kms:DescribeKey`, `secretsmanager:CreateSecret`, `secretsmanager:TagResource`, which the policy file has.
   - **CloudTrail** shows what RDS did on our behalf. The call is made *as the user*, through a forward access session (`invokedBy: rds.amazonaws.com`):
     ```bash
     aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=CreateSecret --max-results 5 \
       --query 'Events[].CloudTrailEvent' --output text
     # "invokedBy":"rds.amazonaws.com" ... "errorCode":"AccessDenied" ... not authorized to perform: secretsmanager:CreateSecret
     #   on resource: rds!cluster-87632d40-9915-4b24-9120-15403505b1e8   (eventTime 05:03:16Z, after the save at ~05:02)
     ```
   - **Probe:** is the new statement live? Tagging a secret that doesn't exist returns *ResourceNotFound* if IAM allows it, *AccessDenied* if not:
     ```bash
     aws secretsmanager tag-resource --secret-id 'station-stream-tf/probe-does-not-exist' --tags Key=probe,Value=1  # ResourceNotFoundException (allowed)
     aws secretsmanager tag-resource --secret-id 'rds!cluster-probe-does-not-exist'     --tags Key=probe,Value=1  # AccessDeniedException (not allowed)
     ```
   - **Size check:** 3,386 non-whitespace characters, under the 5,120 limit for a group's inline policies.
   - **Conclusion:** the saved group policy doesn't contain `CreateRdsManagedMasterSecret`. Next: the owner checks the live JSON in the console.

5. ✅ **Fixed.** The owner re-pasted the policy; the probe flipped from *AccessDenied* to *ResourceNotFound* (statement live), then the apply went through. **Cluster created in 33 s**; the writer instance is the slow part. Lesson: when "I saved it" and the error persists, prove what's live with a harmless probe before re-running a slow apply.

**Result (console: RDS → Databases → `station-stream-tf-db`):** cluster *Available*, engine **16.15**, writer `station-stream-tf-db-1` sized **Aurora serverless (0 - 4 ACUs)**, Internet access gateway *Disabled*, Multi-AZ *No* (single writer on purpose), master user `stationadmin` with credentials in `rds!cluster-b62ee170-…` (*Active*, key `aws/secretsmanager`), parameter group `default.aurora-postgresql16`. The console also shows "RDS Extended Support: Enabled": paid support that only starts after a major version's standard support ends (years away for 16.x); the real answer is to upgrade on schedule.

### L1.2 ✅ Schema and migration (code only, tested locally)

[src/db/schema.sql](../src/db/schema.sql): eight tables (`franchises`, `shows`, `seasons`, `episodes`, `assets`, `stations`, `home_rows`, `home_row_shows`) with text primary keys, foreign keys with `ON DELETE CASCADE`, indexes on the child side of each FK, and JSONB for the asset fields whose shape varies (`availabilities`, `images`, `videos`). [src/db/migrate.js](../src/db/migrate.js) applies the schema, upserts the JSON in one transaction, and creates the read-only role `api_reader`.

**Local proof (throwaway `postgres:16-alpine` container, no AWS):** migration run twice gave identical counts (2 franchises, 4 shows, 4 seasons, 8 episodes, 8 assets, 2 stations, 4 rows, 7 row entries); the GraphQL `Home` query for both stations returned **byte-identical JSON** from the JSON-backed and the Postgres-backed API; `api_reader` could `SELECT` but `DELETE FROM shows` gave `permission denied for table shows`.

### L1.5 / L1.6 ✅ API reads from Aurora, cache-first, `/health` independent (code only, tested locally)

[src/catalog.js](../src/catalog.js): the API boots on the bundled JSON, then loads from Aurora in the background; after that every GraphQL request serves from memory and, if the copy is older than 60 s, triggers one background refresh (stale-while-revalidate, single-flight). No GraphQL traffic means no queries, so Aurora can pause. `/health` reports `catalogSource` and `catalogAgeSeconds` but never queries the database.

**Local failure tests:** (1) database stopped mid-run: requests kept being served, `/health` stayed HTTP 200; (2) database down at boot: served the bundled JSON, `/health` showed `"catalogLastError":"ECONNREFUSED"`; (3) database back: next refresh flipped `catalogSource` to `aurora` with no restart.

**Bug found by the test:** a refused connection in Node arrives as an `AggregateError` with an **empty `message`**, so the first version logged `"error":""` and `/health` hid it (empty string is falsy). Fix: fall back to `err.code`. Interview point: test the failure path, not just the happy path.

### L1.4 ✅ Least privilege: secrets, roles, and the read-only database user

**What & why:** two execution roles, two secrets, two database users, so each piece can only reach what it needs.
- The API's execution role (`station-stream-tf-task-exec`) gets an inline policy `read-api-reader-secret`: `secretsmanager:GetSecretValue` on **only** `station-stream-tf/db/api-reader`. ECS reads it at task start and sets `PGPASSWORD`; the env also has `PGHOST` (cluster endpoint), `PGDATABASE=stationstream`, `PGUSER=api_reader`.
- A separate role `station-stream-tf-migrate-exec` is the **only** one that can read the RDS-managed admin secret (plus the api-reader one, to set that user's password).
- Secret values are injected with `valueFrom = "<secret ARN>:password::"` (pick one JSON key).
- `depends_on` the IAM policy on both task definitions: otherwise a new task can start before its role may read the secret (a race that fails as `AccessDenied` on task start).

```bash
terraform plan -out=tfplan && terraform apply tfplan   # Plan: 6 to add, 1 to change, 1 to destroy (old task-def revision)
```
**Check:**
```bash
aws iam get-role-policy --role-name station-stream-tf-task-exec --policy-name read-api-reader-secret --query PolicyDocument.Statement
aws ecs describe-task-definition --task-definition station-stream-tf --query 'taskDefinition.containerDefinitions[0].secrets'
```

### L1.3 ✅ Migrate + seed as a one-off ECS task

**What & why:** the database is private, so the laptop can't reach it. The migration runs *inside* the VPC as a Fargate task, with the same image and a different command (`node src/db/migrate.js`), wearing the task security group (the only one the DB accepts). Real-world pattern: run migrations as a task before deploying code that needs them.
```bash
REG=897744507899.dkr.ecr.us-east-1.amazonaws.com    # image first: copy GitHub Actions' build into app 2's repo
aws ecr get-login-password | docker login -u AWS --password-stdin $REG
docker pull --platform linux/arm64 $REG/station-stream:4935121
docker tag $REG/station-stream:4935121 $REG/station-stream-tf:4935121 && docker push $REG/station-stream-tf:4935121

cd terraform
eval "$(terraform output -raw migrate_command)"     # aws ecs run-task ... --task-definition station-stream-tf-migrate
aws ecs wait tasks-stopped --cluster station-stream-tf --tasks <task-arn>
aws logs get-log-events --log-group-name /ecs/station-stream-tf --log-stream-name migrate/migrate/<task-id>
```
**Console:** ECS → Clusters → station-stream-tf → Tasks → Run new task → Launch type Fargate → Family `station-stream-tf-migrate` → Networking: default VPC, subnets 1a/1b, security group `station-stream-tf-task`, public IP on → Create.
**Result:** exit code `0` on the first try, `"migration complete","counts":{"franchises":2,"shows":4,"seasons":4,"episodes":8,"assets":8,"stations":2,"home_rows":4,"home_row_shows":7}`, same as the local test.

### L1.5–L1.7 ✅ API on Aurora, live

Rollout to task definition with image `4935121` → `COMPLETED`. Then:
```bash
curl -s https://d1436kyrcdypmk.cloudfront.net/health
# {"status":"ok","version":"4935121","uptimeSeconds":143,"stations":2,"catalogSource":"aurora","catalogAgeSeconds":141}
# one GraphQL request later (copy older than 60 s -> background refresh):
# {"status":"ok",...,"catalogSource":"aurora","catalogAgeSeconds":3}
```
Firebase site https://station-stream-2026.web.app loaded the North station (all 8 episodes, no console errors). Likes still work: toggled off and on, reload showed it liked (Cloud Run function → Atlas, independent of Aurora).

### L1.8 ❌→🔜 Console Query Editor (Data API)

**What & why:** the Query Editor runs SQL from the browser through the **Data API** (HTTPS to RDS, enabled by `enable_http_endpoint = true`), so no network path to the private DB is needed. It logs in with a Secrets Manager secret; we use the **`api_reader`** secret, so the console runs SQL as the read-only user and nobody reads the admin password.

**Errors:** the console showed "Your account doesn't have access to AWS Secrets Manager … to create a secret that is used by the query editor". The CLI version of the same query gave the precise reasons:
```bash
aws rds-data execute-statement --resource-arn arn:aws:rds:us-east-1:897744507899:cluster:station-stream-tf-db \
  --secret-arn arn:aws:secretsmanager:us-east-1:897744507899:secret:station-stream-tf/db/api-reader-IiQeOW \
  --database stationstream --sql "SELECT count(*) FROM episodes"
# AccessDeniedException: ... not authorized to perform: rds-data:ExecuteStatement on resource: ...cluster:station-stream-tf-db
aws secretsmanager list-secrets
# AccessDeniedException: ... not authorized to perform: secretsmanager:ListSecrets
```
**Fix (owner's clicks):** `QueryEditorDataApi` (the five `rds-data:*` statement/transaction actions, only on `cluster:station-stream-*`) and `ListSecretNamesForQueryEditor` (`secretsmanager:ListSecrets` on `*`: it can't be scoped, and it returns names and metadata, never values). `GetSecretValue` on the api-reader secret was already allowed by `ManageStationStreamSecrets`.

---

## Teardown (reverse order of creation)

Dependencies must go first: the service before the cluster, the load balancer before its security group, the task security group before the ALB group it references.

```bash
aws ecs update-service --cluster station-stream --service api --desired-count 0
aws ecs delete-service --cluster station-stream --service api --force
aws ecs delete-cluster --cluster station-stream
aws elbv2 delete-load-balancer --load-balancer-arn <ALB_ARN>        # 💰 stops the main hourly cost
aws elbv2 delete-target-group --target-group-arn <TG_ARN>           # after the ALB is gone
aws ec2 delete-security-group --group-id sg-0f9f51d3b947f0b80       # task group first: it references the ALB group
aws ec2 delete-security-group --group-id sg-0e74dafa314f5550d       # may need a minute while network interfaces release
aws logs delete-log-group --log-group-name /ecs/station-stream
aws iam detach-role-policy --role-name station-stream-task-exec \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
aws iam delete-role --role-name station-stream-task-exec
aws ecr delete-repository --repository-name station-stream --force
# Phase 6: CloudFront must be DISABLED and finish deploying (~5 min) before it can be deleted
aws cloudfront get-distribution-config --id E285IGXEWUIGEW   # note the ETag, set Enabled=false, update-distribution --if-match ETAG
aws cloudfront delete-distribution --id E285IGXEWUIGEW --if-match <new ETag>
aws cloudfront delete-origin-access-control --id E10UJH60KSW2B5 --if-match <ETag>
aws s3 rm s3://station-stream-video-897744507899 --recursive && aws s3api delete-bucket --bucket station-stream-video-897744507899
```

**Check nothing is left:** `aws resourcegroupstaggingapi get-resources --tag-filters Key=project,Values=station-stream`
