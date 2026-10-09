# Station Stream study guide (app 1, built in the AWS console)

This guide is for rebuilding app 1 **by yourself** and being able to explain every piece of it in an interview.

- **[aws-breadcrumbs.md](aws-breadcrumbs.md)** is the full log: every click, command, error and fix, in order. This guide doesn't repeat it. It explains the *why* and tells you which breadcrumbs section (§) to open.
- Read this guide top to bottom once. Then rebuild using section 3, with the breadcrumbs open in a second tab.

**Contents**

1. [The big picture in one page](#1-the-big-picture-in-one-page)
2. [Glossary](#2-glossary)
3. [Build order: rebuild app 1 yourself](#3-build-order-rebuild-app-1-yourself)
4. [The 12 problems we hit and what each teaches](#4-the-12-problems-we-hit-and-what-each-teaches)
5. [Self-test: 20 interview questions](#5-self-test-20-interview-questions)
6. [Job requirements → where this repo shows them](#6-job-requirements--where-this-repo-shows-them)
7. [Aurora Serverless v2: the catalog database (app 2)](#7-aurora-serverless-v2-the-catalog-database-app-2)
8. [Load testing, autoscaling and capacity planning (app 2)](#8-load-testing-autoscaling-and-capacity-planning-app-2)

---

## 1. The big picture in one page

The app is a mini Local Public: **one** backend that serves **several** branded TV stations. A viewer opens `?station=north` or `?station=south`, sees that station's name, colors and home-screen rows, and plays HLS video.

The one design rule to remember: **the API never serves video.** The API answers small questions ("what's on North Valley's home screen?"). Big video files go through a separate path built for big files: S3 storage behind the CloudFront CDN. Real streaming platforms split it the same way.

```
                         ┌──────────────────────────── AWS, region us-east-1 ───────────────────────────┐
                         │                                                                              │
  Viewer's browser       │   PATH A: page + data (small, dynamic)                                       │
  ┌───────────────┐  ①   │   ┌──────────────────────┐  ②   ┌──────────────────────────────────────┐    │
  │ player page   │──────┼──>│ Application Load     │─────>│ ECS service "api" (Fargate)          │    │
  │ (HTML +       │ HTTP │   │ Balancer, port 80    │ :4000│  └─ task: Node.js + Apollo GraphQL   │    │
  │  hls.js)      │<─────┼───│ + security group     │<─────│     reads data/*.json, returns       │    │
  │               │      │   └──────────────────────┘      │     catalog + CloudFront video URLs  │    │
  │               │      │                                  └──────────────────────────────────────┘    │
  │               │      │                                     ▲ image pulled from ECR                   │
  │               │      │                                     │ logs sent to CloudWatch Logs            │
  │               │      │   PATH B: video (big, static)                                                │
  │               │  ③   │   ┌──────────────────────┐  ④   ┌──────────────────────────────────────┐    │
  │               │──────┼──>│ CloudFront (CDN)     │─────>│ S3 bucket (private)                  │    │
  │               │ HTTPS│   │ edge cache near you  │ OAC  │ HLS playlists (.m3u8) + chunks (.ts) │    │
  │               │<─────┼───│ + CORS headers       │signed│                                      │    │
  └───────────────┘      │   └──────────────────────┘      └──────────────────────────────────────┘    │
                         │                                                                              │
                         │   WATCHING: CloudWatch metrics → alarms → SNS topic → your email             │
                         │   SCALING:  Application Auto Scaling keeps CPU ≈ 60% with 1–2 tasks          │
                         │   SHIPPING: git push → GitHub Actions ─OIDC→ IAM role → ECR + ECS deploy     │
                         └──────────────────────────────────────────────────────────────────────────────┘
```

**One sentence per box**

| Box | What it does |
|---|---|
| **Player page** | An HTML page ([public/index.html](../public/index.html)) served by the API container itself; it asks the API for data, then hands video URLs to hls.js. |
| **① → Load balancer (ALB)** | The single public front door: it takes HTTP on port 80 and forwards each request to a healthy container. |
| **ALB security group** | A firewall that lets anyone on the internet reach port 80, and nothing else. |
| **② → ECS service / task** | ECS keeps exactly the number of containers you asked for running, and replaces any that die or fail health checks. |
| **Task security group** | A firewall that lets *only* the load balancer reach the container on port 4000, so the container can't be hit directly. |
| **Node.js + Apollo GraphQL** | The API ([src/server.js](../src/server.js)): `/graphql` answers catalog questions and `/health` tells the load balancer "I'm alive". |
| **ECR** | The private image registry the task's Docker image is pulled from at startup. |
| **CloudWatch Logs** | Where the container's printed log lines go (one JSON line per request). |
| **③ → CloudFront** | A CDN: copies of the video sit in data centers near viewers, and it adds the CORS headers the browser needs. |
| **④ → S3 (via OAC)** | Private file storage for video; Origin Access Control means only *this* CloudFront distribution can read it. |
| **CloudWatch alarms → SNS** | Alarms watch load balancer numbers and email you through an SNS topic when something is wrong (and again when it recovers). |
| **Auto Scaling** | A thermostat for task count: adds a second task when average CPU stays above 60%, removes it when it's quiet. |
| **GitHub Actions + OIDC** | Every push to `main` builds a new image, pushes it to ECR and rolls it out to ECS, using temporary credentials (no stored AWS keys). |

**A request's journey, step by step**

1. Browser asks `http://<alb-dns>/?station=north`. The ALB forwards it to the task, and Express serves `index.html`.
2. The page's JavaScript sends `POST /graphql` with a query like "station north: name, colors, home rows, episodes". Same ALB, same task.
3. The resolvers in [src/schema.js](../src/schema.js) look up the station in `data/stations.json` and the shows in `data/catalog.json`, and build each episode's `hlsUrl` as `VIDEO_BASE_URL + path`. `VIDEO_BASE_URL` is an environment variable in the task definition, set to the CloudFront address.
4. The viewer clicks an episode. hls.js downloads `master.m3u8` from CloudFront, picks a quality (360p/720p/1080p) and fetches 4-second `.ts` chunks, switching quality as bandwidth changes.
5. If CloudFront already has a chunk cached at that edge location, S3 is never touched. If not, CloudFront fetches it from S3 with a signed request, caches it, and returns it.

---

## 2. Glossary

Grouped by topic. Each term is explained in plain words, in the sense it's used in this project.

### Accounts, regions, money

| Term | Meaning |
|---|---|
| **AWS account** | Your billing and security container. Ours is `897744507899`. Everything you create belongs to it. |
| **Root user** | The email login that created the account. It can do anything, including closing the account, so it is never used day to day and has no access keys. |
| **Region** | A geographic group of AWS data centers. We use `us-east-1` (N. Virginia) for everything. |
| **Availability Zone (AZ)** | One separate data center (or group of them) inside a region, such as `us-east-1a`. Spreading across 2+ zones survives one zone failing. |
| **ARN** | Amazon Resource Name: the full unique ID of any AWS thing, e.g. `arn:aws:iam::897744507899:role/station-stream-task-exec`. Policies refer to resources by ARN. |
| **Tag** | A label (key=value) stuck on a resource. We tag everything `project=station-stream` so teardown can find it all with one command. |
| **AWS Budgets** | Sends an email when spending crosses a line. Ours is $10/month, measured *before* credits so it actually fires. |
| **Cost Explorer** | AWS's spending charts. It only turns on about 24 hours after a new account is created, which is why the budget's "exclude credits" filter failed on day one. |
| **CloudShell** | A terminal inside the AWS web console, already signed in as you. Used for the one root-only CLI step. |
| **CLI profile** | A named set of credentials in `~/.aws/`. `AWS_PROFILE=station-stream` makes every command run as our limited user. |

### IAM: who can do what

IAM = Identity and Access Management.

| Term | Meaning |
|---|---|
| **IAM user** | A long-lived identity for a person or program, with a password and/or access keys. Ours is `station-stream-dev`. |
| **Access key** | A key ID + secret pair that lets the CLI act as an IAM user. Long-lived, so it must never go in git. |
| **IAM group** | A bundle of permissions. Users in the group inherit them. Ours is `station-stream-builders`. |
| **Policy** | A JSON document listing which **actions** (e.g. `ecs:UpdateService`) are allowed or denied on which **resources** (ARNs), optionally under **conditions**. |
| **AWS-managed policy** | A policy AWS writes and maintains, e.g. `AmazonECS_FullAccess`. Convenient, but check what it really grants (see problem 9). |
| **Inline policy** | A policy written by you and attached directly to one user, group or role, e.g. [builder-iam-scoped.json](../infra/iam/builder-iam-scoped.json). |
| **Identity-based policy** | A policy attached to *who* (user, group, role). "No identity-based policy allows…" in an error means none of yours grants that action. |
| **Resource-based policy** | A policy attached to the *thing* being accessed, e.g. the S3 bucket policy that lets CloudFront read. |
| **IAM role** | An identity with no password or keys. A trusted service or person "assumes" it and gets temporary credentials. |
| **Trust policy** | The half of a role that says **who** may assume it (e.g. "only `ecs-tasks.amazonaws.com`" or "only GitHub tokens from this repo's `main`"). |
| **Permissions policy** | The half of a role that says **what** it may do once assumed. Trust = who; permissions = what. |
| **STS** | Security Token Service: the AWS service that hands out temporary credentials when a role is assumed. |
| **PassRole** | Permission to hand a role to a service (e.g. "ECS, run this task with role X"). Restricting it stops someone from giving a service a more powerful role than they have. |
| **Service-linked role** | A role AWS creates and owns for one of its services, e.g. `AWSServiceRoleForApplicationAutoScaling_ECSService`. You don't edit it. |
| **Confused deputy** | An attack where another account tricks an AWS service into using *your* role. The `aws:SourceAccount` / `aws:SourceArn` conditions in our trust policy block it. |
| **Least privilege** | Grant only what's needed, on only the resources needed. Example: the deploy role may update only `service/station-stream/api`. |
| **AccessDenied / AuthorizationError** | The error when a policy doesn't allow something. It names the **action**, the **resource**, and the **reason**: read all three. |
| **Access Analyzer** | An IAM tool that checks policies for mistakes. The console's live policy linter uses it; our user isn't allowed to call it (problem 8). |
| **KMS** | Key Management Service: stores encryption keys. We avoided custom KMS keys (S3 uses SSE-S3), so KMS errors in forms were noise (problem 8). |
| **CloudTrail** | AWS's audit log of API calls. The GitHub session name `gha-<run id>` appears there, so you can trace which run did what. |

### Networking

| Term | Meaning |
|---|---|
| **VPC** | Virtual Private Cloud: your own private network inside AWS. Every account has a **default VPC**, which we use. |
| **Subnet** | A slice of the VPC's addresses that lives in **one** Availability Zone. We use two: `us-east-1a` and `us-east-1b`. |
| **Public subnet** | A subnet whose route table sends internet traffic to an internet gateway. All default-VPC subnets are public. |
| **CIDR** | A way to write an address range. `0.0.0.0/0` means "every IPv4 address", i.e. the whole internet. |
| **Security group (SG)** | A firewall around a network interface. It only **allows** (there are no deny rules); anything not listed is blocked. It's stateful, so replies to allowed traffic are let out automatically. |
| **SG-to-SG rule** | A rule whose source is *another security group* instead of an IP range. "Port 4000 from `station-stream-alb`" means only things wearing the ALB's group can connect. |
| **Public IP** | An internet address on the task. Our task needs one to reach ECR, because we skip the NAT gateway. The security group still blocks inbound traffic. |
| **NAT gateway** | A paid box (~$32/month) that lets private-subnet resources reach the internet without public IPs. Skipped here to save money. |
| **DNS name** | A human-readable address. The ALB gets `station-stream-alb-….elb.amazonaws.com`; CloudFront gets `d22r43ct06qav3.cloudfront.net`. |

### Containers and ECS

ECS = Elastic Container Service.

| Term | Meaning |
|---|---|
| **Docker image** | A packaged, read-only snapshot of the app plus everything it needs (Node, libraries, files), built from the [Dockerfile](../Dockerfile). |
| **Container** | A running instance of an image. |
| **Multi-stage build** | A Dockerfile with two `FROM`s: stage 1 has build tools (Tailwind), stage 2 copies only the result, so the final image is smaller and has fewer CVEs. |
| **Image tag** | A name for one image version. We tag with the 7-character git commit (`57b8b14`), so every image traces back to its code. |
| **ECR** | Elastic Container Registry: AWS's private Docker image storage. |
| **Immutable tags** | ECR setting: once `57b8b14` is pushed, that tag can never point at different bytes. Rollbacks are exact. |
| **Scan on push** | ECR checks each pushed image against the public list of known vulnerabilities. |
| **CVE** | Common Vulnerabilities and Exposures: an ID for one publicly known security hole, e.g. in `zlib`. |
| **Lifecycle policy** | ECR rule that deletes old images automatically. Ours keeps the 10 newest. |
| **Image index / manifest list** | A pointer entry that lists several images (e.g. one per CPU type). Docker's default build creates one, which confused ECR (problem 4). |
| **Provenance attestation** | Build metadata ("who built this, from what") that newer Docker attaches as an extra entry. We turn it off with `--provenance=false`. |
| **ECS cluster** | A named grouping of services and tasks. With Fargate there are no servers in it to manage. |
| **Task definition** | The recipe for running the container: image, CPU/memory, chip type, port, environment variables, log destination, roles. See [taskdef.json](../infra/ecs/taskdef.json). |
| **Revision** | Task definitions can't be edited. Each change creates a new numbered revision (`station-stream:1`, `:2`, `:3` …). A deploy means "point the service at revision N". |
| **Task** | One running copy of a task definition (here, one container). |
| **Service** | Keeps the **desired count** of tasks running, replaces failed ones, registers them with the load balancer, and performs deploys. Ours is named `api`. |
| **Fargate** | "Serverless" containers: AWS supplies the machine; you pick only CPU and memory. We use the smallest: 0.25 vCPU, 512 MB, ARM64. |
| **ARM64 / Graviton** | AWS's ARM chips: cheaper than x86 for the same work. Image and Fargate platform must match. |
| **awsvpc network mode** | Each Fargate task gets its own network interface and private IP, which is why the target group uses type `ip`. |
| **Execution role** | The role **ECS itself** uses *before and around* your app: pull the image from ECR, write logs to CloudWatch. Ours: `station-stream-task-exec`. |
| **Task role** | The role **your app's code** uses to call AWS (e.g. read S3). Our app never calls AWS, so we don't have one (problem 3). |
| **ECS Exec** | A feature to open a shell inside a running container. It needs a task role, which is why enabling it failed. |
| **Rolling deploy** | Start new tasks, wait until they're healthy, then stop old ones. Briefly both versions serve traffic (problem 7). |
| **minimumHealthyPercent / maximumPercent** | Deploy limits. `100 / 200` means "never drop below 1 running task; you may briefly run 2", i.e. start new before stopping old. Applies to **deploys only**, not crashes. |
| **Deployment circuit breaker** | If new tasks keep failing to start, ECS stops the deploy and rolls back to the last good revision on its own. |
| **Health check grace period** | Seconds after a task starts during which failed load-balancer health checks are ignored, so slow boots aren't killed. |
| **SIGTERM** | The "please shut down" signal ECS sends before stopping a task. Our server drains in-flight requests when it gets it; `stopTimeout: 30` is how long ECS waits before forcing it. |
| **Steady state** | ECS's word for "the service has the desired number of healthy tasks and no deploy in progress". |

### Load balancing

| Term | Meaning |
|---|---|
| **ALB (Application Load Balancer)** | An HTTP-aware load balancer. Must span 2+ zones. The main hourly cost here (~$0.023/hr plus its public IPs). |
| **Internet-facing** | The ALB has a public DNS name. (The other option, internal, is only reachable inside the VPC.) |
| **Listener** | "Listen on this port and protocol, then do this." Ours: HTTP port 80 → forward to the target group. |
| **Target group** | The list of places traffic may go (our tasks' IPs on port 4000), plus the health check settings. ECS adds and removes tasks automatically. |
| **Target type `ip`** | Targets are registered by IP address, which Fargate requires. |
| **Health check** | The ALB calls `/health` every 15 s. 2 passes = healthy, 3 failures = unhealthy; only healthy targets get traffic. |
| **Draining / deregistration delay** | When a target is removed, the ALB stops sending new requests but lets current ones finish for this long. Default 300 s; we use 30 s. |
| **502 / 503** | Error codes the ALB itself returns. 503 here means "no healthy target to send to". |

### Storage and CDN

| Term | Meaning |
|---|---|
| **S3** | Simple Storage Service: stores files ("objects") in "buckets". Bucket names are global, so ours ends in the account number. |
| **Block Public Access** | Four S3 switches that override anything trying to make the bucket public. All on. |
| **Object Ownership: ACLs disabled** | Access is decided only by policies, not by old-style per-object permission lists. AWS's recommended default. |
| **SSE-S3** | Server-side encryption with keys S3 manages. Chosen over SSE-KMS so CloudFront doesn't also need key permissions. |
| **Content-Type** | Header saying what a file is. `.ts` must be `video/mp2t`; tools often guess TypeScript. |
| **Cache-Control** | Header saying how long CDNs and browsers may keep a copy: 1 year for chunks (never change), 5 minutes for playlists. |
| **CloudFront** | AWS's CDN (Content Delivery Network): hundreds of edge locations cache copies near viewers. |
| **Distribution** | One CloudFront configuration with its own `*.cloudfront.net` address. Ours: `E285IGXEWUIGEW`. |
| **Origin** | Where CloudFront fetches from when it doesn't have a copy. Ours is the S3 bucket. |
| **Edge location** | A CloudFront data center near viewers. |
| **Cache hit / miss** | Hit: the edge already had the file. Miss: it went to the origin. Higher hit ratio = faster and cheaper. |
| **OAC (Origin Access Control)** | CloudFront signs every request to S3 (with SigV4, AWS's request-signing method), and the bucket policy accepts only requests signed by this distribution. Replaces the older OAI. |
| **Cache policy** | Decides what makes two requests "the same" for caching. `CachingOptimized` = URL only, and it respects each object's Cache-Control. |
| **Response headers policy** | Headers CloudFront adds to responses. `CORS-With-Preflight` adds the CORS headers. |
| **CORS** | Cross-Origin Resource Sharing: a browser rule. A page from the ALB's domain may only read files from CloudFront's domain if CloudFront says so in `Access-Control-Allow-Origin`. |
| **Preflight (OPTIONS)** | A permission-check request the browser may send before the real one. That's why OPTIONS is an allowed method. |
| **403 instead of 404** | Without `s3:ListBucket`, S3 answers "forbidden" for missing files, so outsiders can't probe which files exist. Remember this when debugging a bad link. |
| **WAF** | Web Application Firewall (~$14/month). Blocks malicious requests. Skipped: public video with no forms or logins. |
| **Origin Shield / Price class** | An extra paid cache layer, and which edge regions are used. Both left at the cheapest/defaults. |

### Video

| Term | Meaning |
|---|---|
| **HLS** | HTTP Live Streaming: video split into short chunks plus playlists, fetched over plain HTTP, so any CDN can serve it. |
| **`.m3u8` playlist** | A text file. `master.m3u8` lists the qualities; each quality's `index.m3u8` lists its chunks. |
| **`.ts` segment** | One 4-second chunk of video (MPEG transport stream). |
| **Rendition / bitrate ladder** | The same video encoded at several qualities (360p/720p/1080p). |
| **Adaptive bitrate (ABR)** | The player switches renditions as bandwidth changes, so video doesn't stall. |
| **hls.js** | A JavaScript library that plays HLS in browsers that don't support it natively (Chrome, Firefox). |
| **ffmpeg** | The command-line video tool that turns our MP4s into HLS ([scripts/encode-hls.sh](../scripts/encode-hls.sh)). |

### Monitoring, alerting, scaling

| Term | Meaning |
|---|---|
| **CloudWatch** | AWS's monitoring service: logs, metrics, alarms, dashboards. |
| **Log group / retention** | A folder of logs (`/ecs/station-stream`). Retention = how long to keep them; default is forever (and billed), ours is 7 days. |
| **Metric** | A number reported over time, e.g. `HealthyHostCount`. The ALB reports its metrics every minute. |
| **Namespace / dimension** | Namespace = which service the metric is from (`AWS/ApplicationELB`). Dimensions = which specific resource (this load balancer, this target group). |
| **Statistic / period** | How datapoints in a time window are combined (Minimum, Maximum, Sum, Average) and how long the window is (60 s). |
| **Alarm** | Watches one metric and moves between **OK**, **ALARM** and **INSUFFICIENT_DATA**. It can notify on each change. |
| **Datapoints to alarm** | "M out of N": how many of the last N periods must breach before it fires. `2 of 2` ignores single blips. |
| **Treat missing data** | What the alarm assumes when no datapoint arrives: `breaching` (bad), `notBreaching` (fine), `ignore`, or `missing`. The subtle setting (problem 10). |
| **SNS** | Simple Notification Service: publish/subscribe. Alarms publish to a **topic**; every **subscription** (email, SMS, PagerDuty) receives it. |
| **Standard vs FIFO topic** | FIFO keeps strict order but can't send email. We need **Standard**. |
| **Pending confirmation** | An email subscription does nothing until the recipient clicks the confirmation link. |
| **Application Auto Scaling** | The AWS service that changes a service's desired count automatically. |
| **Scalable target** | What is being scaled and its limits: `service/station-stream/api`, min 1, max 2. |
| **Target tracking** | A thermostat policy: "keep average CPU at 60%". It creates and owns two hidden alarms (scale out fast, scale in slowly). |
| **Step / predictive scaling** | Alternatives: fixed rules per threshold, or a model that learns daily patterns (useful for prime-time peaks). |
| **Cooldown** | Waiting time after a scaling action before the next one, so the count doesn't flap. |
| **Chaos test** | Breaking something on purpose (we stopped the only task) to check that recovery and alerting work as you believe. |

### CI/CD and identity

| Term | Meaning |
|---|---|
| **CI/CD** | Continuous Integration / Continuous Delivery: automatically build, test and deploy on every change. |
| **GitHub Actions** | GitHub's CI/CD. A **workflow** ([deploy.yml](../.github/workflows/deploy.yml)) has **jobs**, made of **steps**, run on a **runner** (a GitHub-hosted machine). |
| **OIDC** | OpenID Connect: a standard for signed identity tokens. GitHub signs a token saying "repo X, branch main"; AWS verifies it and issues ~1-hour credentials. No stored keys. |
| **Identity provider (IdP)** | The IAM record that tells AWS to trust tokens signed by `token.actions.githubusercontent.com`. Created once per account; grants nothing by itself. |
| **`aud` claim** | Audience: who the token is meant for. Must be `sts.amazonaws.com`. |
| **`sub` claim** | Subject: who the token is about, e.g. `repo:owner/repo:ref:refs/heads/main`. The trust policy must check it, or any GitHub repo could use the role. |
| **Immutable subject** | GitHub's newer `sub` format that includes numeric owner and repo IDs, so a deleted-and-recreated repo with the same name can't inherit your trust (problem 11). |
| **AssumeRoleWithWebIdentity** | The STS call that swaps an OIDC token for temporary AWS credentials. |
| **Waiter** | Code that polls "is it done yet?" until a condition is true. The deploy action's waiter backs off exponentially (problem 12). |
| **Smoke test** | A quick check after deploy that the live system works. Ours polls `/health` until it reports the new version. |
| **Terraform** | Infrastructure as code: describe resources in files, `plan` shows the diff, `apply` makes it so. App 2 uses it; app 1 is console-built. |

### API

| Term | Meaning |
|---|---|
| **GraphQL** | An API style where the client sends one query naming exactly the fields it wants, to one endpoint (`/graphql`). |
| **Apollo Server** | The Node.js library that runs our GraphQL schema. |
| **Schema / resolver** | The schema lists types and fields ([src/schema.js](../src/schema.js)); a resolver is the function that computes one field's value. |
| **Multi-tenant / white-label** | One platform serving many customers (stations), each with its own branding. Here: `data/stations.json`. |

---

## 3. Build order: rebuild app 1 yourself

### Why this order

Every AWS resource **refers to** others by ID. You can only point at something that already exists, so you build from the bottom of the dependency chain up:

```
Account safety (budget, IAM user)          ← protects you before anything bills
  └─ Image in ECR                          ← the service needs something to run
  └─ Network: VPC/subnets → security groups ← the ALB and tasks need firewalls to sit in
       └─ Execution role + log group       ← the task definition names both
       └─ Cluster                          ← the service lives in it
       └─ Target group → ALB → listener    ← the listener forwards to the target group
            └─ Task definition             ← names image, role, log group
                 └─ Service                ← names cluster, task def, subnets, SG, target group
S3 bucket → upload video → CloudFront+OAC  ← independent track; only needs to exist before
  └─ new task definition revision           ← you point VIDEO_BASE_URL at it
SNS topic → subscription → alarms          ← alarms need the ALB/TG (to watch) and the topic (to notify)
Autoscaling                                ← needs the service
OIDC provider → deploy role → workflow     ← the role names the provider; the workflow names the role
```

**Two tracks.** The video track (S3 + CloudFront) doesn't depend on ECS at all. You could build it first and put the CloudFront address in the very first task definition. We built ECS first, which is why there's a "rolling deploy for a config change" step.

**Teardown is the exact reverse** for the same reason: you can't delete a security group that something still uses.

### Before you start

- **Costs.** From step 8 (the ALB) onward, things bill by the hour: about **$0.05/hour** total (ALB, one Fargate task, public IPs). Do the ECS part in one sitting and tear down when you stop (breadcrumbs "Teardown").
- **Every terminal:** `export AWS_PROFILE=station-stream AWS_REGION=us-east-1`. The shell is zsh: pass multiple IDs as separate words (problem 2).
- **Values that change on a rebuild.** New resources get new IDs. Write yours down as you go, and update these places in the repo before deploying:

  | Value | Where it's used |
  |---|---|
  | ALB DNS name | `PUBLIC_URL` in [deploy.yml](../.github/workflows/deploy.yml) |
  | CloudFront domain | `VIDEO_BASE_URL` in [taskdef.json](../infra/ecs/taskdef.json) |
  | ALB and target group ARN suffixes | the alarm dimensions (`LB=…`, `TG=…`) in breadcrumbs §7.3 |
  | Security group IDs, subnet IDs | the service's network settings |
  | Distribution ID | the bucket policy's `AWS:SourceArn` (the console wizard writes it for you) |

  Account ID, bucket name, repo name, role names and the OIDC `sub` stay the same.
- **App 2.** A separate Terraform build (app 2) may exist in the same account. Check with `aws resourcegroupstaggingapi get-resources --tag-filters Key=project,Values=station-stream` before you start, so you don't collide with or delete its resources.

### The checklist

Each step: what to build, which breadcrumbs section has the clicks, and how to prove it worked.

#### Part A: safety and the app

- [ ] **1. Budget alarm** (breadcrumbs §0.1). Do this before anything can bill.
  - ✔ Check: Billing → Budgets shows `station-stream-10usd` with 3 alerts.
- [ ] **2. IAM group, scoped policy, user, access key** (§0.2). Permissions go on the group; the user inherits them.
  - ✔ Check: `aws sts get-caller-identity` → ARN ends in `user/station-stream-dev`.
  - ✔ Check: `aws iam create-user --user-name should-not-exist` → **AccessDenied**. A failure here is the success.
- [ ] **3. App runs locally**: `npm install && npm run dev`, then open `http://localhost:4000/?station=north`.
  - ✔ Check: `curl localhost:4000/health` → `{"status":"ok",…}`.
- [ ] **4. Encode video** with `npm run video:encode` (needs `video/source/*.mp4`, not in git).
  - ✔ Check: `ls video/out/*/master.m3u8` lists one file per clip, and video plays locally from `localhost:8080`.

#### Part B: image

- [ ] **5. ECR repository**, immutable tags, scan on push, lifecycle rule (§4.1, §4.2).
  - ✔ Check: `aws ecr describe-repositories --repository-names station-stream --query 'repositories[0].imageTagMutability'` → `IMMUTABLE`.
- [ ] **6. Build and push** an ARM64 image tagged with the commit, `--provenance=false` (§4.3). Use **View push commands** in the console.
  - ✔ Check: `aws ecr describe-images --repository-name station-stream --query 'imageDetails[].[imageTags[0],imageManifestMediaType]' --output text` → exactly **one** entry per push, with a tag. Untagged extras mean problem 4.
  - ✔ Check: the image's scan shows no HIGH/CRITICAL findings (problem 5).

#### Part C: network and plumbing (still free)

- [ ] **7. Find the default VPC and two subnets** in different zones (§5.1). Read-only.
  - ✔ Check: you've written down 1 VPC ID and 2 subnet IDs in 2 different AZs.
- [ ] **8. Two security groups** (§5.2): `station-stream-alb` (80 from `0.0.0.0/0`) and `station-stream-task` (4000 from the **ALB group**, not an IP range).
  - ✔ Check: EC2 → Security Groups → `station-stream-task` → Inbound rules → Source shows `sg-…` (the ALB group).
- [ ] **9. Execution role** `station-stream-task-exec` (§5.3), trust = `ecs-tasks.amazonaws.com`, permissions = `AmazonECSTaskExecutionRolePolicy`.
  - ✔ Check: `aws iam get-role --role-name station-stream-task-exec --query 'Role.AssumeRolePolicyDocument.Statement[0].Principal'` → `ecs-tasks.amazonaws.com`.
- [ ] **10. Log group** `/ecs/station-stream`, 7-day retention (§5.4).
  - ✔ Check: `aws logs describe-log-groups --log-group-name-prefix /ecs/station-stream --query 'logGroups[0].retentionInDays'` → `7`.
- [ ] **11. Cluster** `station-stream`, Fargate (§5.5).
  - ✔ Check: `aws ecs describe-clusters --clusters station-stream --query 'clusters[0].status'` → `ACTIVE`.

#### Part D: load balancer and service (💰 billing starts here)

- [ ] **12. Target group** `station-stream-tg`: type IP, port 4000, health check `/health`, deregistration delay 30 s; **don't register targets** (§5.6).
  - ✔ Check: target group exists with 0 targets. That's correct for now.
- [ ] **13. ALB** `station-stream-alb`: internet-facing, both subnets, ALB security group, listener HTTP:80 → target group (§5.7, §5.8).
  - ✔ Check: `curl http://<alb-dns>/` returns **503**. That's correct: the ALB works, there's just nothing healthy behind it yet.
- [ ] **14. Task definition** from [taskdef.json](../infra/ecs/taskdef.json) via "Create with JSON" (§5.9). Fix the image tag (and `VIDEO_BASE_URL` if CloudFront already exists) first.
  - ✔ Check: ECS → Task definitions → `station-stream:1` is ACTIVE.
- [ ] **15. Service** `api`: desired 1, Fargate, both subnets, **task** security group, public IP **on**, attach to the existing ALB + target group, circuit breaker with rollback, grace period 30 s, min 100% / max 200% (§5.10). **Don't** enable ECS Exec (problem 3).
  - ✔ Check: task goes PROVISIONING → PENDING → RUNNING; target goes `initial` → `healthy` (~2 min); `curl http://<alb-dns>/health` → 200 with your version.
  - ✔ Check: `curl -m 5 http://<task-public-ip>:4000/health` **times out**. That proves the firewall chain works.
  - If stuck: the service's **Events** tab is the first place to look (§5.11).

#### Part E: video through the CDN

- [ ] **16. Private S3 bucket** `station-stream-video-<account>`: Block all public access on, ACLs disabled, SSE-S3 (§6.1).
  - ✔ Check: `aws s3api get-public-access-block --bucket <bucket>` → all four `true`.
- [ ] **17. Upload** `video/out` with the CLI, three passes with explicit Content-Type and Cache-Control (§6.2). Bulk work belongs in the CLI.
  - ✔ Check: `aws s3api head-object --bucket <bucket> --key ship-it/1080p/seg_000.ts --query ContentType` → `video/mp2t`.
- [ ] **18. CloudFront distribution** with OAC ("Allow private S3 bucket access"), redirect HTTP→HTTPS, GET/HEAD/OPTIONS, `CachingOptimized`, `CORS-With-Preflight`, no WAF (§6.3).
  - ✔ Check: status `Deployed`; `curl -I https://<dist>.cloudfront.net/ship-it/master.m3u8` → **200**; the same path straight from `https://<bucket>.s3.amazonaws.com/…` → **403**.
- [ ] **19. New task definition revision** with `VIDEO_BASE_URL=https://<dist>.cloudfront.net`, then **Update service** to it (§6.4). Skip if you set it in step 14.
  - ✔ Check: the service's deployments list shows a single entry, `COMPLETED`; the player's status line says `from <dist>.cloudfront.net`, and video plays on the public URL.

#### Part F: monitoring and scaling

- [ ] **20. SNS topic** `station-stream-alerts`, type **Standard**, tagged (§7.1). Expect the KMS banner (ignore it) and possibly `SNS:TagResource` denied (problem 9: the owner fixes the policy).
  - ✔ Check: SNS → Topics shows it, with tag `project=station-stream`.
- [ ] **21. Email subscription**, then **click the confirmation link** (§7.2).
  - ✔ Check: the subscription's ARN is a real ID, not `PendingConfirmation`.
- [ ] **22. Four alarms** (§7.3). Build `no-healthy-targets` in the console to learn the screens; the other three can be CLI.
  - ✔ Check: `aws cloudwatch describe-alarms --alarm-name-prefix station-stream --query 'MetricAlarms[].[AlarmName,StateValue]' --output table` → 4 alarms, moving from `INSUFFICIENT_DATA` to `OK` within a few minutes.
- [ ] **23. Service auto scaling**: min 1, **max 2**, target tracking on CPU 60% (§7.4).
  - ✔ Check: `aws cloudwatch describe-alarms --alarm-name-prefix TargetTracking --query 'MetricAlarms[].AlarmName'` → two auto-created alarms (AlarmHigh, AlarmLow).
- [ ] **24. Chaos test**: run the curl loop, stop the task, watch (§7.5). Before you start, write down which alarms you predict will fire.
  - ✔ Check: a new task appears within seconds; ~30 s of 503s; `elb-5xx` emails ALARM then OK. Compare with your prediction (problem 10).

#### Part G: deploy pipeline

- [ ] **25. OIDC identity provider** for `token.actions.githubusercontent.com`, audience `sts.amazonaws.com` (§8.1).
  - ✔ Check: IAM → Identity providers lists it.
- [ ] **26. Deploy role** `station-stream-github-deploy`: Web identity, **fill in repo and branch** (they default to `*`), inline policy from [github-deploy-policy.json](../infra/iam/github-deploy-policy.json) (§8.2). Then **replace the trust policy** with [github-oidc-trust.json](../infra/iam/github-oidc-trust.json), which has the immutable `sub` (problem 11).
  - ✔ Check: `aws iam get-role --role-name station-stream-github-deploy --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition'` shows both `aud` and `sub`.
- [ ] **27. Workflow**: update `PUBLIC_URL` and any ARNs in [deploy.yml](../.github/workflows/deploy.yml), push a code change to `main` (§8.3).
  - ✔ Check: `gh run list --limit 1` → success; `curl http://<alb-dns>/health` shows the new commit as `version`; `gh secret list` is **empty**.

#### Part H: tear down

- [ ] **28. Teardown in reverse order** (breadcrumbs "Teardown").
  - ✔ Check: `aws resourcegroupstaggingapi get-resources --tag-filters Key=project,Values=station-stream` returns nothing you meant to delete, and the next day's bill stops growing.

---

## 4. The 12 problems we hit and what each teaches

These are your interview stories. For each one, practise saying the four parts out loud in under a minute.

### 1. IAM denials, on purpose and by surprise (breadcrumbs §0.3, §5.3)

- **Symptom:** `AccessDenied … not authorized to perform: iam:CreateRole on resource: role/evil-admin because no identity-based policy allows…`
- **Diagnosis:** This was a deliberate negative test. The scoped policy allows IAM role actions only on `role/station-stream-*`. Every AccessDenied message has three parts: the **action**, the **resource**, and the **reason**. Together they tell you exactly which policy line is missing.
- **Fix:** None needed: it proved the guardrail works. Later, `station-stream-task-exec` was created without trouble *because* it matches the pattern. (Related day-one snag: the budget's "exclude credits" filter failed because Cost Explorer takes ~24 h to switch on, so the budget was created with the API in CloudShell instead.)
- **Takeaway:** "I test permissions negatively, not just positively: I prove the user *can't* escalate itself to admin. A user that can create any role can create an admin role and assume it, so role creation was scoped by name prefix."

### 2. zsh doesn't split variables on spaces (§5.7)

- **Symptom:** `InvalidSubnet: The subnet ID 'subnet-0bd6… subnet-07cd…' is not valid` when creating the ALB with `--subnets $SUBNETS`.
- **Diagnosis:** The error quoted **one** ID containing a space. bash splits an unquoted `$VAR` on spaces into separate words; zsh (the macOS default) does not. AWS received a single ID with a space in it.
- **Fix:** Pass each subnet as its own word: `--subnets subnet-0bd6… subnet-07cd…`.
- **Takeaway:** "Read the error literally. It showed exactly what AWS received. Scripts that work in bash can break in zsh; in CI, set the shell explicitly."

### 3. `taskRoleArn` required by ECS Exec (§5.10)

- **Symptom:** `InvalidParameterException: a valid taskRoleArn is not being used` when creating the service with `--enable-execute-command`.
- **Diagnosis:** ECS has two roles. The **execution role** is used by ECS itself (pull the image, write logs). The **task role** is used by your app's code, and ECS Exec's agent runs inside the task, so it needs a task role. We only had an execution role.
- **Fix:** Our app never calls AWS, so we dropped the flag instead of creating a role we didn't need.
- **Takeaway:** "Execution role = what ECS needs to *start* the container; task role = what the app needs *while running*. I didn't create permissions just to make an error go away."

### 4. Docker provenance attestations confused ECR (§4.4)

- **Symptom:** One push created **3** entries in ECR: a tagged index plus 2 untagged children. The vulnerability scan said "not found".
- **Diagnosis:** `aws ecr describe-images` with the manifest media type showed an *image index*. Newer Docker attaches a provenance (build metadata) record by default, which makes the push an index. The scanner scans real images, not indexes. Worse: the lifecycle rule counts untagged entries, so it could later have deleted the real image while the tag still pointed at it, and ECS would fail to pull.
- **Fix:** Deleted the 3 entries and rebuilt with `--provenance=false`: one push = one plain image. The workflow uses the same flag.
- **Takeaway:** "A default in the build tool silently changed what landed in the registry. I verified the artifact, not just the exit code, and found a latent failure: the cleanup rule could have deleted a running image."

### 5. HIGH CVE in zlib (§4.5)

- **Symptom:** ECR scan on tag `51b2e63`: `{"HIGH": 1}`, zlib `1.3.2-r0` in the Alpine base image.
- **Diagnosis:** `describe-image-scan-findings` named the package and version. Alpine had already published a fix; the `node:24-alpine` base image just hadn't been rebuilt yet.
- **Fix:** `RUN apk upgrade --no-cache` in the runtime stage of the [Dockerfile](../Dockerfile). New tag `57b8b14` scanned clean. Trying to re-push a different image as `51b2e63` was refused: tags are immutable.
- **Takeaway:** "Scan on push catches vulnerabilities before deploy. Base images lag behind OS patches, so the build pulls security updates itself. Immutable tags mean the bad image can't be quietly replaced: you fix forward with a new tag."

### 6. ffmpeg ate the loop's input (scripts, before AWS)

*Not in the breadcrumbs: this happened in the local video phase. The fix is visible in [scripts/encode-all.sh](../scripts/encode-all.sh) and [scripts/encode-hls.sh](../scripts/encode-hls.sh).*

- **Symptom:** The batch script loops over a list of clips with `while read file slug`, but the loop stopped early instead of encoding every clip.
- **Diagnosis:** `while read` reads its list from standard input (stdin). ffmpeg *also* reads stdin by default (it listens for keypresses like `q`), so the first ffmpeg call swallowed the rest of the list, and `read` found nothing left.
- **Fix:** Belt and braces: `ffmpeg -nostdin` in the encoder, and `</dev/null` on the call inside the loop, so the child can't touch the loop's input.
- **Takeaway:** "A shared resource between parent and child, here stdin, caused silent partial work with exit code 0. Batch jobs should check their output count, not just the exit status."

### 7. Version skew during a rolling deploy (§6.4)

- **Symptom:** During the deploy that switched video to CloudFront, repeated API calls alternated between `localhost` and `cloudfront` URLs for about 50 seconds.
- **Diagnosis:** A rolling deploy with min 100% / max 200% starts the new task *before* stopping the old one. While both are healthy, the ALB round-robins between them. Polling every ~12 s showed the timeline: new task healthy → both serving → old task draining (30 s) → steady state, ~2.5 min total, zero downtime.
- **Fix:** Nothing to fix: it's expected. The lesson is about how you design changes.
- **Takeaway:** "Zero-downtime deploys mean two versions serve at once. API changes must be backward compatible: add fields first, remove them only after every client has moved (expand, then contract). Otherwise you need blue/green with an instant switch."

### 8. Red herrings: KMS and Access Analyzer banners (§7.1, §8.2)

- **Symptom:** Red banners in the console: `Couldn't retrieve KMS keys … not authorized to perform kms:DescribeKey` (SNS form) and `not authorized to perform access-analyzer:ValidatePolicy` (IAM policy editor).
- **Diagnosis:** Read *which action* failed. Both were the **form** trying to fill optional helpers (a key-picker dropdown and a live policy linter) using permissions our user doesn't have. Neither was part of what we were creating.
- **Fix:** Ignored both. Validated the policy another way (read the editor's contents back: valid JSON, 5 statements).
- **Takeaway:** "Not every red error matters. I triage by the action named in the message. During an incident, chasing a red herring costs minutes, so I ask 'is this action on my critical path?'"

### 9. `SNS:TagResource` denied (§7.1)

- **Symptom:** `AuthorizationError: … not authorized to perform: SNS:TagResource on resource: …:station-stream-alerts`. No topic was created at all.
- **Diagnosis:** Our SNS rights came from the managed policy `CloudWatchFullAccessV2`. Instead of guessing, we read what it actually grants (`aws iam get-policy-version`): only Create/Subscribe/List. No tagging, and **no DeleteTopic/Unsubscribe**, so teardown would have failed later too. Create-with-tags is all-or-nothing: if tagging is denied, the whole create fails.
- **Fix:** A new statement in [builder-iam-scoped.json](../infra/iam/builder-iam-scoped.json) allowing tag/delete/unsubscribe only on `…:station-stream-*` topics. The owner applied it (IAM permission changes are a human step). The retry succeeded *with* the tag, which proved the change.
- **Takeaway:** "'FullAccess' in a managed policy name doesn't mean full. I read the policy document instead of guessing, and fixed the next failure (teardown) at the same time, scoped to our naming prefix."

### 10. The chaos test: only one of four alarms fired (§7.5)

- **Symptom:** Stopped the only task, predicting all 4 alarms would fire. ~30 s of 503s (24 failed requests). Only `elb-5xx` fired, ~2.5 min after the first error, and returned to OK ~9 min after the last.
- **Diagnosis:** Pulled the raw metrics with `get-metric-statistics`, one per alarm:
  - `target-5xx`: the app never returned an error, it just wasn't there. No data.
  - `unhealthy-targets`: ECS **deregistered** the task (draining) before stopping it, so it never *failed* a health check. Stayed 0.
  - `no-healthy-targets`: the outage minute's datapoint was **missing entirely** (the ALB publishes nothing while no targets are registered). "Treat missing as breaching" only applies when *every* datapoint in the look-back window is missing; the minutes before and after had 1.0, so a 30-second gap was skipped. A multi-minute outage would have fired it.
  - `elb-5xx`: the ALB answered 503 itself, 18 + 6 = 24, exactly matching the curl log.
- **Fix:** No config change: understanding the gap *was* the outcome. To remove the blip itself you need 2+ tasks in different zones; `minimumHealthyPercent` only protects deploys.
- **Takeaway:** "I tested my alerts and my prediction was wrong. The user-facing signal (load balancer 5xx) caught a 30-second blip that capacity metrics missed. Alert on what users experience. Alarms also lag: detection took longer than the outage. One task is a single point of failure; we accepted that for cost."

### 11. OIDC `sub` didn't match: GitHub's immutable subject (§8.3)

- **Symptom:** First workflow run failed: `Could not assume role with OIDC: Not authorized to perform sts:AssumeRoleWithWebIdentity`.
- **Diagnosis:** That error almost always means a trust-policy condition didn't match, usually `sub`. Compare what GitHub *sends* with what AWS *expects*: `gh api repos/<owner>/<repo>/actions/oidc/customization/sub` showed `use_immutable_subject: true`. GitHub sent `repo:ideaguy3d@14084686/station_stream@1409232207:ref:refs/heads/main`; the console wizard had built `repo:ideaguy3d/station_stream:ref:refs/heads/main`.
- **Fix:** Replaced the trust policy with [github-oidc-trust.json](../infra/iam/github-oidc-trust.json) (ID-based `sub`, `StringEquals`), then **re-ran the same commit** so only the fix was being tested. All green in 3m26s.
- **Takeaway:** "With name-only subjects, if the repo were deleted, someone could create one with the same name and inherit our AWS access. Numeric IDs are never reused. Debug auth by comparing the claim actually sent with the condition expected."

### 12. The deploy was fast; knowing it was done was slow (§8.3)

- **Symptom:** The second pipeline run took 7m28s vs 3m26s. The "Deploy to ECS" step took 428 s vs 178 s.
- **Diagnosis:** Compared timestamps: ECS reached steady state in ~2.5 min (from its own service events), but the step ran ~7 min. The action's "wait for stability" waiter polls with **exponential backoff** (15 s, 30 s, 60 s … up to 2 min apart), so it noticed ~4.5 min late.
- **Fix:** None applied; documented. Options: a custom poll loop with a fixed short interval, or rely on the smoke test (which already proves the new version is live).
- **Takeaway:** "Measure each phase separately. The slow part was the *observer*, not the system. Backoff is great for not hammering APIs, but it adds latency to detection."

---

## 5. Self-test: 20 interview questions

Answer out loud first, then open the box.

<details><summary>1. Walk me through what happens when a viewer presses play.</summary>

The page (served by the API container through the ALB) already called `/graphql` and got episode data including an `hlsUrl` on CloudFront. hls.js fetches `master.m3u8` from CloudFront, picks a quality, then fetches 4-second `.ts` chunks. CloudFront serves them from the edge cache, or on a miss fetches from the private S3 bucket using OAC-signed requests. The API is never in the video path.
</details>

<details><summary>2. Why doesn't the API serve the video files?</summary>

Video is large, static and cacheable; the API is small and dynamic. A CDN serves big static files from locations near viewers, and it scales without adding containers. Putting video through the API would make Fargate tasks pay for bandwidth and CPU they don't need, and a traffic spike would take down the catalog too.
</details>

<details><summary>3. Trust policy vs permissions policy?</summary>

The trust policy says **who** may assume the role (e.g. `ecs-tasks.amazonaws.com`, or GitHub tokens from one repo's `main`). The permissions policy says **what** the role can do once assumed. Both must allow it.
</details>

<details><summary>4. Execution role vs task role in ECS?</summary>

The execution role is used by ECS to start the task: pull the image from ECR, send logs to CloudWatch, fetch secrets. The task role is used by the application code while running, e.g. to read S3. We have only an execution role because the app doesn't call AWS.
</details>

<details><summary>5. How is the container protected if it has a public IP?</summary>

Its security group allows inbound port 4000 only from the ALB's security group (an SG-to-SG rule), nothing from the internet. We proved it: curling the task's public IP times out. The public IP exists only so the task can reach ECR without a NAT gateway (~$32/month).
</details>

<details><summary>6. What's a task definition revision and why does it matter for deploys?</summary>

Task definitions are immutable. Each change (new image, new env var) registers a new numbered revision. A deploy is "update the service to revision N". Rollback is "update it back to N−1". Even a config-only change like `VIDEO_BASE_URL` goes through a new revision and a rolling deploy.
</details>

<details><summary>7. How does a zero-downtime deploy work here, and what's the catch?</summary>

`minimumHealthyPercent=100, maximumPercent=200`: ECS starts the new task, waits for it to pass ALB health checks, then drains the old one (30 s deregistration delay). The catch is version skew: for about 50 s both versions serve traffic, so API changes must be backward compatible.
</details>

<details><summary>8. What does the deployment circuit breaker do?</summary>

If new tasks repeatedly fail to start or fail health checks, ECS marks the deploy failed and automatically rolls back to the last revision that worked, instead of looping forever.
</details>

<details><summary>9. Does minimumHealthyPercent=100 protect you if a task crashes?</summary>

No. It only governs deployments. When the only task crashed or was stopped, viewers got ~30 s of 503s until the replacement was healthy. The protection for crashes is 2+ tasks in different Availability Zones.
</details>

<details><summary>10. How does CloudFront read from a private S3 bucket?</summary>

Origin Access Control: CloudFront signs every origin request (SigV4), and the bucket policy allows `s3:GetObject` only for principal `cloudfront.amazonaws.com` with `AWS:SourceArn` equal to our distribution. Block Public Access stays on. Direct S3 URLs return 403.
</details>

<details><summary>11. Why does a missing file return 403 instead of 404?</summary>

The bucket policy grants only `GetObject`, not `ListBucket`. Without list permission, S3 won't reveal whether a key exists, so it answers 403 either way. Good for security, confusing when debugging a typo in a URL.
</details>

<details><summary>12. Why was CORS needed, and where is it configured?</summary>

The page comes from the ALB's domain and the video from CloudFront's domain. The browser only lets JavaScript (hls.js) read cross-domain responses if they carry `Access-Control-Allow-Origin`. CloudFront's `CORS-With-Preflight` response headers policy adds it, and OPTIONS is allowed for preflight requests.
</details>

<details><summary>13. Why different Cache-Control for .ts and .m3u8?</summary>

Segments never change once encoded, so they can be cached for a year (`immutable`), maximizing cache hits. Playlists might change (and for live streams change constantly), so they get 5 minutes. Long TTL on what's fixed, short TTL on what points to it.
</details>

<details><summary>14. What does "treat missing data" mean, and how did you set it?</summary>

It's what an alarm assumes when no datapoint arrives. 5xx counts publish nothing when there are no errors, so missing = fine (`notBreaching`). HealthyHostCount is always published while targets exist, so missing = bad (`breaching`). Wrong choices give alarms that never fire or never clear.
</details>

<details><summary>15. You stopped the only task. Which alarm fired and why not the others?</summary>

Only `elb-5xx`. The app never returned errors (no target 5xx); ECS deregistered the task before stopping it, so it never became "unhealthy"; and HealthyHostCount had a single missing minute between good minutes, which "missing = breaching" doesn't count. The ALB's own 503s exactly matched the 24 failed requests. Lesson: alert on user-facing symptoms.
</details>

<details><summary>16. How does target tracking autoscaling work?</summary>

You set a target (60% average CPU). Application Auto Scaling creates two alarms: CPU above 60% for 3 minutes → add a task (fast), below 54% for 15 minutes → remove one (slow). Asymmetric because under-capacity hurts users, while an extra task for a few minutes costs pennies. Max is 2 as a cost cap.
</details>

<details><summary>17. How does GitHub Actions deploy without stored AWS keys?</summary>

The job has `id-token: write`, so GitHub issues a signed OIDC token with claims like `aud=sts.amazonaws.com` and `sub=repo:…:ref:refs/heads/main`. The `configure-aws-credentials` action calls `AssumeRoleWithWebIdentity`; IAM checks the signature against the registered identity provider and the claims against the role's trust policy, then returns ~1-hour credentials. `gh secret list` is empty.
</details>

<details><summary>18. What's the most common OIDC trust mistake?</summary>

Not checking `sub` (or leaving repo/branch as `*` in the console wizard). Then any GitHub repo, or any branch or fork, could assume your deploy role. We pin the exact repo by numeric ID and branch `main`, with `StringEquals`.
</details>

<details><summary>19. Why immutable tags tagged by git commit?</summary>

Every running container traces back to an exact commit, and a tag always means the same bytes, so rollback to `57b8b14` is exact and nobody can silently replace a scanned image. The workflow skips the build when the tag already exists, so re-runs don't fail on push.
</details>

<details><summary>20. A station's app is down at 7pm. How would you investigate this stack?</summary>

Scope first: one station or all, page or video? Check recent deploys (GitHub Actions run, ECS service events): if correlated, roll back to the previous revision. API path: ALB target health, `elb-5xx` vs `target-5xx` (LB with no targets vs app errors), service events, CloudWatch Logs. Video path: CloudFront errors, curl the `.m3u8` through CloudFront, remember 403 can mean "missing file". Mitigate first (rollback, scale up), communicate, then root cause and postmortem.
</details>

---

## 6. Job requirements → where this repo shows them

| Local Public requirement | Shown in this repo | Where |
|---|---|---|
| **AWS ECS** | ✅ Fargate ARM64 service behind an ALB, rolling deploys, circuit breaker, self-healing | [taskdef.json](../infra/ecs/taskdef.json), breadcrumbs Phase 5 and §7.5 |
| **CloudFront / CDN** | ✅ Distribution with OAC to a private S3 bucket, cache and CORS policies, per-file Cache-Control | breadcrumbs Phase 6 |
| **Aurora Serverless** | ✅ App 2: Aurora PostgreSQL Serverless v2 (0–4 ACU, auto-pause), private, managed admin secret, read-only app user, Terraform | [terraform/database.tf](../terraform/database.tf), breadcrumbs Phase L1, section 7 below |
| **PostgreSQL / MongoDB** | ✅ Catalog in Postgres (8 tables, FKs, JSONB, migration task); likes in MongoDB Atlas via a Cloud Run function | [src/db/](../src/db/), [gcp-breadcrumbs.md](gcp-breadcrumbs.md) |
| **GCP Cloud Functions / Firebase / Cloud Build** | ✅ Firebase Hosting UI, Cloud Run function for likes, Cloud Build trigger, uptime check on the AWS API | [gcp/](../gcp/), [gcp-breadcrumbs.md](gcp-breadcrumbs.md) |
| **Terraform** | ✅ App 2 entirely in Terraform (app 1 console-built on purpose, to learn each resource) | [terraform/](../terraform/) |
| **GitHub Actions** | ✅ Build → push → deploy → smoke test on push to `main`, OIDC, concurrency lock, native ARM runner | [deploy.yml](../.github/workflows/deploy.yml), breadcrumbs Phase 8 |
| **Monitoring / alerting** | ✅ 4 CloudWatch alarms → SNS email with recovery notices, JSON request logs, chaos-tested | breadcrumbs §7.1–§7.5, [src/server.js](../src/server.js) |
| **Autoscaling** | ✅ Target tracking on CPU 60%, 1–2 tasks | breadcrumbs §7.4 |
| **Security** | ✅ Scoped IAM user (can't escalate), least-privilege deploy role, OIDC (no keys), SG-to-SG firewall, private bucket + OAC, scan on push, immutable tags, non-root container, confused-deputy conditions | [infra/iam/](../infra/iam/), breadcrumbs §0.2, §4, §5.2, §6.3, §8.2 |
| **Node.js + GraphQL** | ✅ Apollo Server 5 on Express 5, `/health`, graceful shutdown on SIGTERM | [src/](../src/) |
| **Containers / Docker** | ✅ Multi-stage build, OS patches, healthcheck, exec-form CMD | [Dockerfile](../Dockerfile) |
| **Streaming / HLS** | ✅ ffmpeg 3-rung ABR ladder, hls.js player with quality switching | [scripts/encode-hls.sh](../scripts/encode-hls.sh), [public/index.html](../public/index.html) |
| **Multi-tenant (stations)** | ✅ One API, per-station branding and home rows | [data/stations.json](../data/stations.json) |
| **Cost awareness** | ✅ $10 budget, smallest Fargate size, no NAT, 7-day logs, ECR lifecycle, autoscaling max 2, teardown | breadcrumbs §0.1 and "Teardown" |

**Honest gap sentence for the interview:** "I built and operated both sides: ECS, CloudFront, Aurora Serverless v2 and monitoring on AWS, Firebase, a Cloud Run function and Cloud Build on GCP, with app 2 fully in Terraform. What I haven't done is run it under real production load or with a team; the load test (spike, autoscaling, capacity planning) is my next step."

---

## 7. Aurora Serverless v2: the catalog database (app 2)

Built in L1 with Terraform ([terraform/database.tf](../terraform/database.tf)); every step, error and fix is in breadcrumbs Phase L1.

### What it is, in plain words

- **Aurora** is AWS's own database engine that speaks PostgreSQL (or MySQL). Storage is separate from compute: the data lives in a shared, 6-copy storage layer across 3 AZs, and the "database servers" (instances) attach to it. That's why adding a reader is fast: there is nothing to copy.
- **Cluster vs instance.** The *cluster* is the storage plus the endpoints (`station-stream-tf-db.cluster-….rds.amazonaws.com` always points at the writer). An *instance* is the compute. We have one **writer**; a **reader** in a second AZ would give read scaling and failover in about 30 s.
- **Serverless v2** means the instance class is `db.serverless`: capacity scales in **ACUs** (Aurora Capacity Units, roughly 2 GiB RAM plus matching CPU each) in 0.5-ACU steps, within the min/max you set. Ours is **0–4 ACU**.
- **Auto-pause (0 ACU):** after `seconds_until_auto_pause` (300 s, the minimum) with **no connections**, compute stops and you pay only for storage. The first new connection resumes it in roughly 15 s. Any open connection, even an idle one, keeps it awake.
- **Cost model:** per ACU-second, plus storage (GB-month) and I/O. Our idle cost is pennies a month.

### How the pieces fit

```
 Browser ─▶ CloudFront ─▶ ALB ─▶ ECS task "api" ──5432 (SG-to-SG only)──▶ Aurora writer (private)
                                   │  env PGHOST/PGUSER=api_reader                ▲
                                   │  PGPASSWORD ◀── Secrets Manager (api-reader)  │
 One-off ECS task "migrate" ──────────────────────────────────────────────────────┘
   PGPASSWORD ◀── Secrets Manager (rds!cluster-…, created and rotated by RDS)
 Console Query Editor ─HTTPS─▶ Data API ─▶ cluster (logs in with the api-reader secret)
```

- **Private database:** no public access, and its security group allows 5432 **only from the task security group** (a group reference, not an IP range).
- **Two database users:** the admin (`stationadmin`, password generated by RDS into Secrets Manager with `manage_master_user_password`) is used only by the migration task. The API logs in as **`api_reader`**, which can only `SELECT`. Different ECS execution roles read different secrets.
- **Migrations as a task:** the same image with a different command (`node src/db/migrate.js`) runs inside the VPC before the code that needs it. It's idempotent: upserts, `CREATE TABLE IF NOT EXISTS`.
- **Cache-first API:** the catalog changes rarely, so the API keeps it in memory and refreshes it in the background at most once a minute, and only when GraphQL traffic arrives (stale-while-revalidate). Database load doesn't grow with viewers, and with no viewers there are no queries, so Aurora pauses.
- **Health checks that don't cascade:** `/health` *reports* `catalogSource` and `catalogAgeSeconds` but never queries Aurora. If it did, a database blip would make the load balancer kill every task at once, turning a degraded dependency into a total outage.

### Problems we hit (interview stories)

1. **Free plan restriction**, not IAM: `FreeTierRestrictionError … you need to set WithExpressConfiguration`. Express clusters live outside your VPC behind an internet gateway, with IAM auth only, and Terraform can't create them. The owner upgraded to a Paid plan (unused credits carry over).
2. **Reserved word:** database name `catalog` is rejected (PostgreSQL's `pg_catalog`).
3. **KMS:** `KMSKeyNotAccessibleFault … key [null]`. RDS uses AWS-managed keys on your behalf, and the caller still needs `kms:DescribeKey` (and `CreateGrant` via RDS).
4. **The managed secret:** RDS creates `rds!cluster-…` **using the caller's permissions**. The scoped policy didn't cover that name. The fix seemed not to work until CloudTrail (`invokedBy: rds.amazonaws.com`) and a harmless probe (tag a non-existent secret: *NotFound* = allowed, *AccessDenied* = not) proved the saved policy was missing the statement.
5. **An empty error message:** in the local failure test, a refused connection in Node arrives as an `AggregateError` with `message: ""`, so the API hid the reason. Fixed by falling back to `err.code`. Test the failure path, not only the happy path.

### Things to be ready to talk about

- **RDS Proxy:** pools and reuses connections for bursty clients (Lambda, many short-lived tasks) and makes failover faster for apps. We don't need it with a few long-lived ECS tasks with small pools. It also only works inside a VPC.
- **ORM (Prisma):** a schema file generates a typed client and migration files. Good for big teams and fast schema change. We used plain SQL with `pg` because 8 tables and one read path didn't justify it.
- **Data API:** SQL over HTTPS with IAM + a secret, no network path or driver needed. Handy for the console and for Lambda. Our API uses a normal `pg` connection.
- **Production differences:** a reader in a second AZ, `deletion_protection = true`, a final snapshot, longer backups, TLS with CA verification (`verify-full` with the RDS CA bundle), and a minimum capacity above 0 if the ~15 s resume is unacceptable.

---

## 8. Load testing, autoscaling and capacity planning (app 2)

Done in L2 with **k6** ([loadtest/spike.js](../loadtest/spike.js)); numbers and commands in breadcrumbs Phase L2.

### The experiment

Each k6 **virtual user (VU)** acts like a viewer: the same GraphQL `Home` query the page sends, then a 1-second pause, so 300 VUs ≈ 300 req/s. **Thresholds** make a run pass or fail (under 1% errors, p95 under 800 ms). Three runs:

| Run | Config | Result |
|---|---|---|
| 1. Baseline, 10 VUs × 5 min | 1 task | 10 req/s, **5% CPU**, p95 117 ms, 0 errors |
| 2. Spike 10 → 300 VUs in 30 s, hold 5 min | CPU 60%, max 2, cooldowns 300 s | 0 errors, p95 124 ms. **One task carried ~300 req/s at 65% CPU.** Second task arrived ~6 min later, *after* the spike ended |
| 3. Same spike | + requests-per-task policy, max 6, scale-out cooldown 60 s | 3 × 502 (0.003%), p95 136 ms. Second task again ~5 min late, then a **needless third** after the spike |

### What it taught (the interview stories)

1. **Caching is the cheapest capacity.** The in-memory catalog (L1) costs ~0.5 ms CPU per request, so one 0.25 vCPU task absorbed a 30× spike. The database never noticed either (0.5 ACU throughout).
2. **Reactive autoscaling has a floor (~5 min here):** target tracking waits for **3 one-minute datapoints** above target, CloudWatch publishes them 1–2 min late, and a task needs ~40 s to start and pass health checks. Swapping CPU for request count didn't help, because with the cache CPU rises in the same minute as traffic. A request-count metric only leads when work is slow (I/O, database calls).
3. **A short scale-out cooldown overshoots:** after 60 s the alarm still held the last spike minute (measured with 1 task), so target tracking computed `ceil(2 × 17,700 / 15,000) = 3`. The cooldown must exceed metric delay + task start, so we use 180 s. Scale-in stays slow (AlarmLow needs **15** low minutes) so the service doesn't flap.
4. **Load tests find bugs that unit tests don't:** three **502**s came from a keep-alive mismatch. The ALB keeps idle connections for 60 s, Node closes them after 5 s, and the ALB occasionally reuses a closing one. Fix: `keepAliveTimeout = 65 s` (greater than the ALB's idle timeout).
5. **Change one owner per resource:** the console's *Update service* form re-submits autoscaling policies that Terraform owns, so a manual reset used the narrow CLI call (`--desired-count 1` only).

### Capacity planning, the formula

**One task ≈ 300 req/s at ~65% CPU; plan ≈ 250 req/s per task.** For a peak of P req/s: `tasks = ⌈P / 250⌉ + 30–50% headroom`, never below 2 in production (two AZs). A 1,000 req/s premiere → 4 + 50% → **6**.

Because reactive scaling is ~5 min late, a short spike is served by whatever is already running:
- **Known events** (pledge drives, premieres, election night): **scheduled scaling** raises the minimum beforehand. For a station-branded app, the schedule is known.
- **Unknown spikes:** headroom (min 2, ~55% target) plus caching (in-memory, CDN for cacheable GETs).
- **What to watch:** ALB `TargetResponseTime`, `HTTPCode_Target_5XX` vs `HTTPCode_ELB_5XX` (app errors vs load balancer: 502 = bad connection, 503 = no healthy targets, 504 = timeout), `RequestCountPerTarget`, ECS `CPUUtilization`, and the autoscaling **activity history**, which names the alarm behind every decision.

