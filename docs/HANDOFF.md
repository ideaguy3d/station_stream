# Handoff: where we are and what's next

> **New Claude session: read this first**, then [CLAUDE.md](../CLAUDE.md) (working rules), [STUDY_GUIDE.md](STUDY_GUIDE.md) (beginner explanations), and [aws-breadcrumbs.md](aws-breadcrumbs.md) (every AWS step, error and fix, in order). Don't re-derive what's below; build on it.

Last updated: 2026-10-07, ~23:30 PT, end of the first (very long) session. GCP plan revised to v2 (frontend on GCP, backend on AWS).

## 1. Who and why

- The owner is interviewing for **Systems Reliability Engineer at Local Public** (job: https://payroll.justworks.com/jobs/150adf17-bb10-4777-b270-96aa609e2045-job). **About 12 working hours remain before the interview** (as of the timestamp above).
- They are strong in Python, PHP, SQL and AWS data work (EMR, S3), and new to ECS, CloudFront, Terraform, GitHub Actions and GCP. They understand the high level; Claude does the low-level driving (console clicks, commands) and **explains as it goes**. Goal: sound credible in the interview and understand the architecture.
- Cost is not a constraint (AWS Free plan with $100 credits; a fresh GCP account with $300 credits), but keep hourly-billed things visible.

## 2. Current state (all live)

| | App 1: `station-stream` | App 2: `station-stream-tf` |
|---|---|---|
| Built by | AWS console (Claude drove, owner watched) | Terraform ([terraform/](../terraform/)), local state, git-ignored |
| URL | http://station-stream-alb-565835838.us-east-1.elb.amazonaws.com/?station=north | http://station-stream-tf-alb-862429135.us-east-1.elb.amazonaws.com/?station=north |
| Video CDN | `d22r43ct06qav3.cloudfront.net` | `d990usezj0kzv.cloudfront.net` |
| Deploys | GitHub Actions on push to `main`, OIDC role `station-stream-github-deploy` ([deploy.yml](../.github/workflows/deploy.yml)) | `terraform apply` |
| Alerts | 4 CloudWatch alarms → SNS email (confirmed) | same, `station-stream-tf-*` |
| Cost | ~$0.05/hr | ~$0.05/hr |
| Remove with | Teardown section of aws-breadcrumbs.md | `cd terraform && terraform destroy` |

AWS basics: account `897744507899`, region `us-east-1`, CLI profile `station-stream` (IAM user `station-stream-dev`, scoped policy [infra/iam/builder-iam-scoped.json](../infra/iam/builder-iam-scoped.json)). Always `export AWS_PROFILE=station-stream AWS_REGION=us-east-1`.

**Phases done:** 0–9 (setup, API + player, HLS, Docker, ECR, ECS + ALB, S3 + CloudFront, monitoring + autoscaling + chaos test, GitHub Actions OIDC, Terraform app 2).

**Not done / known gaps:**
- **Aurora Serverless + ORM**: deliberately skipped (owner's call). Be ready to *talk* about it: Aurora Serverless v2 scales in ACUs (capacity units), can auto-pause to 0 when idle, PostgreSQL-compatible; an ORM like Prisma maps rows to objects; RDS Proxy pools connections for bursty serverless clients.
- **Phase 10** (teardown script + README "what I learned"): not done. README.md is the original pre-build version.
- The IAM user can't call `tag:GetResources` (needed for the "find everything by tag" teardown check).
- Owner's own rebuilds (apps 3 and 4): **after** the interview.

## 3. What Local Public is (from their site, blog and job post)

- Station-branded streaming apps for **~20 PBS stations** (WETA+, HPM+, WQED+, SCETV+, Arizona PBS, OPB…) on **10 platforms**: Apple TV, Google TV, Fire TV, Roku, LG, Samsung, iOS, iPadOS, Android, web. "6 weeks from signature to app store." Custom CMS; PBS integrations (Passport, SSO, MVault, TV listings); AI personalization; segmented in-app messaging; "CDP-ready" first-party analytics.
- **Spun out of Cascade PBS on July 1, 2026** as an independent Public Benefit Corporation (CEO post by Kevin Colligan). Startup mindset, cost-conscious (federal defunding pressure on public media).
- **Release 2.10 shipped 2026-10-07**: radio livestreams on mobile/web, Apple/Google age verification for Texas SB 2420. **3.0** (UX refresh, audio on TV) is coming.
- "Our cloud architecture (AWS and Google Cloud Platform)." The job lists **different** services per cloud (AWS: ECS, CloudFront, Aurora Serverless; GCP: Cloud Functions, Firebase, Cloud Build; plus FlightControl, Terraform, GitHub Actions, PostgreSQL **and** MongoDB). So: a **division of labor, not an A/B test** of clouds.

### Architecture hypothesis (agreed with the owner, still a guess)

**AWS = backend, GCP/Firebase = app-facing side.**
- **One Node.js GraphQL API on ECS** serves all 10 platforms (GraphQL exists for exactly this: each client asks for only the fields it needs). It talks to **Aurora Postgres** (likely structured data: stations, shows, seasons, entitlements) and **MongoDB** (likely flexible per-user documents such as "My List" / the 3.0 "Liked Videos", or CMS content). **CloudFront** likely serves images, app assets and cached API responses.
- **Video itself comes from PBS** (Media Manager + PBS's CDN). Our self-hosted HLS was a learning stand-in.
- **Firebase** is the *web* front end (Hosting) and, inside the native apps, a **toolbox of SDK services**: Auth, Cloud Messaging (push), In-App Messaging ("Talk to Your Viewers"), Remote Config, Analytics, Crashlytics, App Distribution (beta builds). It does **not** build or ship the TV/phone apps: those use Xcode, Android Studio, Roku BrightScript/SceneGraph, LG webOS / Samsung Tizen web toolkits, and are released through each **app store**. **Roku has no Firebase SDK** and must call the API directly.
- **Clients most likely call the AWS API directly.** Cloud Functions are most likely **event-driven side jobs**: Firebase triggers (user created → member record), **webhooks** (PBS Passport/MVault, donation platforms), **scheduled syncs** (e.g. Media Manager catalog), small per-user features. Routing every request through a function to AWS would add a cross-cloud hop: latency, egress fees, and a database exposed across clouds ("data gravity").
- **Cloud Build** plausibly builds/deploys the web app, functions and containers on GCP.
- Our app 1 "UI on ECS" is just `express.static` handing the browser a file; the **browser** renders it. ECS's real job is the API.

Interview questions to ask them: how responsibilities split across AWS and GCP; where Aurora vs MongoDB data lives; how they get one view of monitoring across both clouds; appetite to consolidate.

### ECS vocabulary (restaurant analogy)

| ECS | Analogy | Ours |
|---|---|---|
| Cluster | The restaurant building (with Fargate, just a named grouping) | `station-stream` |
| Task definition | Versioned recipe card (image, CPU/memory, env, port); never edited, only new revisions | `station-stream:3` |
| Task | One dish being cooked: a running copy with its own IP; replaced on deploy/crash | `69b981aa…` |
| Service | Kitchen manager: keeps N tasks running, replaces failures, wires the load balancer, rolling deploys, autoscaling | `api` |

A "new backend app" in a real company is usually **another service in the same cluster** (`api`, `cms`, `worker`), not a new cluster.

## 4. Next: GCP version, **plan v2: "frontend on GCP, backend on AWS"** (draft)

Supersedes the earlier "copy the whole app onto GCP" idea. Brainstormed 2026-10-07 late; **no building yet**. Confirm the open questions below before G0.

```
 Web app (Firebase Hosting) ──GraphQL (HTTPS)──▶ AWS app 2: CloudFront ▶ ALB ▶ ECS service `api` ▶ (Aurora: later)
        │  Firebase Auth                                                ▲
        └── "like" a show ──▶ Cloud Run function ──▶ MongoDB Atlas (on GCP)
                               Cloud Monitoring uptime check ──────────┘  (GCP watching AWS)
 Cloud Build: deploys Hosting + the function on push to main
```

| Piece | Plan |
|---|---|
| Web UI | `public/` moves to **Firebase Hosting** (HTTPS, global CDN). Calls the AWS GraphQL API. |
| Backend | **App 2** (Terraform) becomes the backend, because it's easiest to change safely in code. No third AWS stack needed. App 1 stays as the console-built reference. |
| HTTPS for the API | Firebase Hosting is HTTPS-only; the ALB is plain HTTP, so browsers would block the calls (**mixed content**). Fix: **CloudFront in front of the ALB** (free `*.cloudfront.net` HTTPS, caching disabled or short for the API) + **CORS** middleware in the API allowing the Firebase origin. All via Terraform. |
| Cloud Function | A small per-user feature mirroring Local Public's 3.0 "Liked Videos": `likeShow` / `listLikes`, verifies the **Firebase Auth** ID token, stores likes in **MongoDB Atlas**. Event-driven/side-job role, like the real thing. |
| Auth | Firebase Auth (anonymous or Google sign-in: open question). |
| MongoDB | **Atlas M0 free tier hosted on GCP** (`us-central1`); connection string in **Secret Manager**. Network gotcha: functions have no fixed egress IP without Cloud NAT, and M0 has no private networking, so allow `0.0.0.0/0` + TLS + strong password for learning. |
| CI/CD | **Cloud Build** trigger on push to `main` (GCP paths only): build CSS → deploy function → `firebase deploy --only hosting`, as a dedicated least-privilege service account. |
| Monitoring | **Cloud Monitoring uptime check** on the AWS API's `/health` + alert → email: cross-cloud observability. |
| Video | Keep app 2's CloudFront for HLS (stand-in for PBS's CDN). |
| Aurora Serverless + Prisma | Back in scope **for later** (Terraform on app 2): catalog in Postgres, likes in MongoDB, mirroring the likely real split. Not before the interview unless time allows. |
| Who drives | **Claude drives** (browser console + CLI) and explains, same as AWS. |

**Status 2026-10-08:** G0 done (project `station-stream-2026`, Firebase on Blaze, site https://station-stream-2026.web.app). G1 done: app 2's API over HTTPS at **https://d1436kyrcdypmk.cloudfront.net** with CORS for the web.app/firebaseapp.com origins (image `461037e`). G2 done: UI live at **https://station-stream-2026.web.app** (build: `API_BASE=… npm run build:hosting`, deploy: `cd gcp && firebase deploy --only hosting`). G3 done: liked videos (anonymous Firebase Auth → Cloud Run function `likes` as SA `likes-fn` → Atlas M0 on GCP us-central1, URI in Secret Manager `atlas-uri`). Security debts: rotate the Atlas password, replace atlasAdmin user with a readWrite app user. G4 done: Cloud Build trigger `gcp-deploy` (region us-central1) runs [gcp/cloudbuild.yaml](../gcp/cloudbuild.yaml) on push to main for gcp/**, public/**, scripts/build-hosting.sh, as SA `cloudbuild-deployer`; the function image is built by SA `likes-build`. Decisions: CloudFront in front of ALB, anonymous Firebase Auth, Aurora after the interview. Details in [gcp-breadcrumbs.md](gcp-breadcrumbs.md).

### Open questions (settled 2026-10-08, see status above)
1. HTTPS for the API: **CloudFront in front of ALB** (recommended) vs. a Cloud Function proxy (server-to-server avoids mixed content, but adds the cross-cloud hop to every request).
2. Firebase Auth: anonymous (no login UI, simplest) vs. Google sign-in (more realistic).
3. Aurora before or after the interview (time: ~12 working hours left at writing, ~3–4 h reserved for studying STUDY_GUIDE.md).

### Phases (stop after each, per CLAUDE.md)
- **G0 Setup** (owner: Google Cloud free trial $300, MongoDB Atlas account; anything with sign-up, passwords or cards). Project, **billing budget alert**, install `gcloud` (Homebrew *cask* `google-cloud-sdk` or Google's installer; formulas compile from source on macOS 14) and `firebase-tools` (npm). Enable APIs (off by default per project): Cloud Functions, Cloud Run, Cloud Build, Artifact Registry, Secret Manager, Firebase, Firebase Hosting, Identity Toolkit (Auth), Logging, Monitoring. Firebase **Blaze** plan (functions require it). Dedicated service accounts instead of the default compute account (which has broad Editor rights).
- **G1 Backend prep on AWS (Terraform, app 2):** CloudFront in front of the ALB; CORS in the API (allow the `*.web.app` origin); new image via the normal deploy.
- **G2 Firebase Hosting:** web UI on Hosting calling the AWS API over HTTPS; video still from app 2's CloudFront.
- **G3 Auth + Atlas + Cloud Run function:** Firebase Auth; Atlas M0 on GCP; `likeShow`/`listLikes` function verifying ID tokens; Secret Manager; max instances 2.
- **G4 Cloud Build:** trigger on push; deploy Hosting + function; smoke test.
- **Stretch:** G5 Cloud Monitoring uptime check on AWS `/health` + alert; G6 Aurora Serverless v2 + Prisma on app 2 via Terraform; G7 Terraform `google` provider for the GCP side.

### Repo and docs conventions for GCP
- GCP config in `gcp/` (firebase.json, cloudbuild.yaml, function code); shared web UI stays in `public/`.
- Log every GCP step in **`docs/gcp-breadcrumbs.md`** (same format as aws-breadcrumbs.md).
- Add `gcp/**` to `paths-ignore` in `.github/workflows/deploy.yml` so GCP-only commits don't redeploy AWS app 1.
- Never commit secrets: the Atlas connection string goes only into Secret Manager.

### AWS ↔ GCP vocabulary (interview cheat sheet)

| AWS (built) | GCP |
|---|---|
| Account + IAM user/role | Project + Google account / **service account** + IAM role binding |
| ECS Fargate service | **Cloud Run** service (container) / **Cloud Run function** (code) |
| Task definition revision | Cloud Run **revision** |
| ECR | **Artifact Registry** |
| ALB + target group health checks | Built into Cloud Run (HTTPS URL, health probes); global external Application Load Balancer when needed |
| S3 | **Cloud Storage** |
| CloudFront | **Cloud CDN** (or Firebase Hosting's CDN) |
| CloudWatch Logs / metrics / alarms | **Cloud Logging** / **Cloud Monitoring** / alerting policies |
| SNS email | Monitoring **notification channel** |
| ECS target-tracking autoscaling | Automatic per-request scaling; **min/max instances**, concurrency |
| GitHub Actions + OIDC | **Cloud Build** triggers; for GitHub Actions → GCP: **Workload Identity Federation** (the keyless OIDC equivalent) |
| Secrets Manager | **Secret Manager** |
| AWS Budgets | **Billing budget** alerts |
| Aurora Serverless (Postgres) | Cloud SQL / AlloyDB (not used here); MongoDB Atlas runs on either cloud |

## 5. How to resume

Tell Claude: *"Read docs/HANDOFF.md, settle the open questions in section 4, then start G0."* Claude should confirm the owner has created the Google Cloud and MongoDB Atlas accounts first.
