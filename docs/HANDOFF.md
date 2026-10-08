# Handoff: where we are and what's next

> **New Claude session: read this first**, then [CLAUDE.md](../CLAUDE.md) (working rules), [STUDY_GUIDE.md](STUDY_GUIDE.md) (beginner explanations), and [aws-breadcrumbs.md](aws-breadcrumbs.md) (every AWS step, error and fix, in order). Don't re-derive what's below; build on it.

Last updated: 2026-10-07, ~23:00 PT, end of the first (very long) session.

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
- "Our cloud architecture (AWS and Google Cloud Platform)." The job lists **different** services per cloud (AWS: ECS, CloudFront, Aurora Serverless; GCP: Cloud Functions, Firebase, Cloud Build; plus FlightControl, Terraform, GitHub Actions, PostgreSQL **and** MongoDB). Best guess: AWS = core API/CMS/DB/CDN; GCP/Firebase = app-side plumbing (messaging, analytics, config) + event-driven Cloud Functions (webhooks, syncs). **Not** an A/B test of clouds. Good interview questions: how responsibilities split across clouds, appetite to consolidate, unified observability across both.

## 4. Next: the GCP version (app 5). Decisions already made

| Decision | Choice |
|---|---|
| API | **Cloud Run functions** (formerly "Cloud Functions 2nd gen"; renamed 2024) running the same Node.js + Apollo GraphQL code |
| Player page **and** video | **Firebase Hosting** (option A: simplest, global CDN, ~$0). Cloud Storage + Cloud CDN + global load balancer (option B, CloudFront-equivalent) is a stretch goal |
| Database | **MongoDB Atlas** free tier (M0) **hosted on GCP**, connected via the MongoDB Node driver; connection string in **Secret Manager**. Not Firestore |
| CI/CD | **Cloud Build** trigger on push to `main` |
| Who drives | **Claude drives** (console in the built-in browser + CLI), explaining every screen, same as AWS |
| Scope / time | ~3 h for G0–G4 below; stretch only if time allows. ~3–4 h reserved for the owner to study STUDY_GUIDE.md |

### Proposed phases (stop after each, summarize, wait for "go", per CLAUDE.md)

**G0. Setup** *(owner does anything involving sign-up, passwords or card details; Claude can't)*
- Owner: create the Google account / GCP free trial ($300, 90 days) and a **MongoDB Atlas** account.
- Create project (e.g. `station-stream-gcp-<suffix>`; project IDs are global and permanent). Set a **billing budget alert** (e.g. $10) like AWS Budgets.
- Install `gcloud` (Homebrew cask `google-cloud-sdk`, or Google's installer; macOS 14 means Homebrew *formulas* compile from source, casks download binaries) and `firebase-tools` (`npm i -g`). `gcloud auth login`, `gcloud config set project …`.
- **Enable APIs** (GCP has them off per project): Cloud Functions, Cloud Run, Cloud Build, Artifact Registry, Secret Manager, Firebase, Firebase Hosting, Logging, Monitoring.
- Upgrade Firebase to the **Blaze** (pay-as-you-go) plan: Cloud Functions require it; free quotas still apply.
- Least privilege: create **dedicated service accounts** for the function runtime and for Cloud Build instead of the default compute service account (which has broad Editor rights). That's the GCP version of our scoped IAM user and roles.

**G1. MongoDB Atlas**
- M0 free cluster, cloud provider **GCP**, region near the functions (e.g. `us-central1`). Database user with a generated password.
- **Network access gotcha:** Cloud Run functions don't have fixed outbound IPs (that needs Cloud NAT, ~$30+/month), and the free tier has no private networking, so allow `0.0.0.0/0` for learning (TLS + strong password). Production answer: static egress IP via Cloud NAT, or Private Service Connect on a dedicated tier.
- Seed `stations` and `shows` collections from `data/*.json` (a small script). Store the connection string in **Secret Manager**.

**G2. API as a Cloud Run function**
- Small refactor so both clouds share code: `src/app.js` builds the Express + Apollo app; `src/server.js` (AWS container) calls `listen()`; a function entry exports the app for the Functions Framework. Add a data-source switch (`DATA_SOURCE=json|mongo`) so AWS keeps using JSON.
- Deploy: region `us-central1`, newest GA Node runtime (`gcloud functions runtimes list`), min instances 0, **max instances 2** (cost cap, like ECS max 2), secret mounted as an env var, runs as the dedicated service account.
- Talk-track: cold starts and min instances; each deploy creates a **revision**, and traffic can be split or rolled back between revisions (the Cloud Run counterpart of ECS task definition revisions and the circuit breaker).

**G3. Firebase Hosting (page + video)**
- Hosting serves `public/` (+ built `styles.css`) and the HLS files from `video/out` under `/video/`.
- `firebase.json`: rewrite `/graphql` → the function (same origin, so **no CORS** needed); `headers` for `.m3u8` / `.ts` Content-Type and Cache-Control (same values as S3).
- `VIDEO_BASE_URL=https://<project>.web.app/video`. Verify playback and `x-cache` style CDN headers.

**G4. Cloud Build CI**
- Connect GitHub (Cloud Build repository connection), trigger on push to `main` with an included-files filter for GCP-relevant paths.
- `cloudbuild.yaml`: `npm ci` → build CSS → `gcloud functions deploy` → `firebase deploy --only hosting`, running as the Cloud Build service account with only the roles it needs. Smoke-test `/health` like the GitHub workflow does.

**Stretch (in order):** G5 Cloud Monitoring uptime check on `/health` + alert policy → email, logs-based 5xx metric, then a "bad deploy → roll back revision" chaos test. G6 Cloud Storage + Cloud CDN + global external load balancer (option B). G7 Terraform `google` provider.

### Repo and docs conventions for GCP
- GCP config lives in `gcp/` (firebase.json, cloudbuild.yaml, function entry, seed script); shared app code stays in `src/`.
- Log every GCP step in **`docs/gcp-breadcrumbs.md`**, same format as aws-breadcrumbs.md (What & why / CLI / Console / Check / ✅ ❌→✅ 🔜).
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

Tell Claude: *"Read docs/HANDOFF.md and start G0 of the GCP plan."* Claude should confirm the owner has created the Google Cloud and MongoDB Atlas accounts first, then proceed.
