# Plan L1 + L2: Aurora Serverless v2 catalog, then a traffic-spike test

Agreed with the owner on 2026-10-08 (the evening before the interview). Budget: **about 4 hours** for both. Read [HANDOFF.md](HANDOFF.md) and [CLAUDE.md](../CLAUDE.md) first; this file only adds the plan.

## Decisions (settled, don't re-ask)

1. **Aurora PostgreSQL Serverless v2** (RDS), not Aurora DSQL: the job post says "Aurora Serverless", and that's most likely what Local Public runs.
2. **App 2 only** (`station-stream-tf`, Terraform in [terraform/](../terraform/)): it's the backend the Firebase UI calls (https://d1436kyrcdypmk.cloudfront.net), and Terraform makes changes reviewable (`plan`) and fast.
3. The Firebase site and https://tv.ranklab.org (which iframes it) **may be degraded for ~10 minutes during L2**, and the G5 uptime alert email may fire. That's intended: a realistic exercise.
4. **Cap ECS at 6 tasks** during the spike test.
5. **No ORM:** plain SQL with `pg`. Be ready to *talk* about Prisma (schema file → typed client + migrations), but don't add it.

## Working rules (from CLAUDE.md, repeated because they matter)

- Explain each AWS piece in 2–3 plain sentences **before** creating it. The owner is learning.
- Terraform makes the resources, but **show each new resource in the AWS console** in the built-in browser afterwards (RDS → Databases, Secrets Manager, ECS, CloudWatch), explaining the screens.
- **IAM permission grants are the owner's clicks.** When the IAM user `station-stream-dev` lacks a permission, show the exact error, explain it, and hand the owner exact click steps. Never use root, never widen beyond what an error proves is needed.
- Log every AWS step in [aws-breadcrumbs.md](aws-breadcrumbs.md) **in the same step** (What & why / CLI / Console / Check / status; keep real error messages and the diagnosis). GCP steps (if any) go in [gcp-breadcrumbs.md](gcp-breadcrumbs.md).
- **Warn before anything billed by the hour**, with the cost. Aurora Serverless v2 is billed per ACU-hour.
- **Never put secrets in chat, code, git or breadcrumbs.** Passwords live only in Secrets Manager.
- `export AWS_PROFILE=station-stream AWS_REGION=us-east-1`. Tag everything `project=station-stream` (Terraform `default_tags` already does this).
- Use **Context7** for current docs (Terraform AWS provider `aws_rds_cluster`, `pg`, k6) before writing config. Facts below marked *(verify)* are from memory.
- Commits: one short subject line + co-author trailer; push to `origin main` after each commit. `terraform/**` and `docs/**` don't trigger the AWS deploy workflow; `src/**` does (it redeploys app 1 too, which is fine).
- **Stop after L1** with a summary + 1–2 interview sentences, and wait for "go" before L2.

## Current state you're building on (verified 2026-10-08)

- App 2 = Terraform: default VPC, ALB `station-stream-tf-alb-862429135…`, CloudFront API `d1436kyrcdypmk.cloudfront.net` (`E7BB4SHJWN2O6`, caching disabled), ECS cluster `station-stream-tf`, service `api`, task definition `station-stream-tf:2`, image tag `461037e` (pinned in `var.image_tag`).
- ECS tasks run in **public subnets with public IPs** (no NAT gateway). App 2 has only a task **execution** role ([terraform/iam.tf](../terraform/iam.tf)), **no task role**.
- Autoscaling ([terraform/monitoring.tf](../terraform/monitoring.tf)): **min 1, max 2, target tracking on CPU 60 %, 300 s cooldowns** both ways.
- The catalog is **two JSON files** ([data/catalog.json](../data/catalog.json), [data/stations.json](../data/stations.json)) baked into the image and loaded at startup by [src/catalog.js](../src/catalog.js) into an in-memory object the GraphQL resolvers read ([src/schema.js](../src/schema.js)). There is **no SQL database yet**.
- New images: push to `main` → GitHub Actions builds `station-stream:<sha7>` and deploys app 1 → copy the image into ECR repo `station-stream-tf` → bump `var.image_tag` → `terraform plan -out=tfplan && terraform apply tfplan`. Wait for `rolloutState=COMPLETED`, not `aws ecs wait services-stable` (it returns too early).
- Docker works locally. **Homebrew compiles from source on this Mac (macOS 14, Tier 3)**: avoid `brew install`; use Docker images or official release binaries.

---

## L1: Move the catalog into Aurora PostgreSQL Serverless v2 (~2 h)

**Goal:** the API serves stations and shows from Aurora, and **the database is never a single point of failure** for page views.

| Step | What | Who |
|---|---|---|
| L1.0 | **Permissions check:** run `terraform plan` early and let real errors show what `station-stream-dev` lacks (likely `rds:*` for clusters, instances, subnet groups and tags; Secrets Manager for the RDS-managed secret; `rds-data:*` for the Query Editor). Owner adds the minimum, with exact click steps from Claude | owner clicks |
| L1.1 | **Terraform** `terraform/database.tf`: `aws_db_subnet_group` (default-VPC subnets in 2 AZs); `aws_security_group` `station-stream-tf-db` allowing **5432 only from the task security group** (SG-to-SG reference, not CIDR); `aws_rds_cluster` engine `aurora-postgresql` (a 16.x version that supports 0 ACU *(verify)*), `engine_mode = "provisioned"` + `serverlessv2_scaling_configuration { min_capacity = 0, max_capacity = 4, seconds_until_auto_pause = 300 }` *(verify)*, `manage_master_user_password = true` (RDS keeps the admin password in Secrets Manager), `enable_http_endpoint = true` (Data API → console Query Editor), `storage_encrypted = true`, `skip_final_snapshot = true`, `deletion_protection = false` (learning project), not publicly accessible; one `aws_rds_cluster_instance` with `instance_class = "db.serverless"` (one writer; mention that a reader in a 2nd AZ gives fast failover). **Warn the cost first** (see Costs) | Claude |
| L1.2 | **Schema** `src/db/schema.sql`: `stations`, `home_rows` (station, position, title), `home_row_shows`, `franchises`, `shows`, `seasons`, `episodes`, `assets`, with **text primary keys** (the catalog already has ids like `sh-code-lab`), **foreign keys**, and `JSONB` where the shape is flexible (e.g. station theme/branding). Keep the GraphQL schema unchanged | Claude |
| L1.3 | **Migrate + seed as a one-off ECS task** (the DB is private; the Mac can't reach it): `src/db/migrate.js` applies `schema.sql` and upserts the JSON (idempotent: safe to run twice). Run it with `aws ecs run-task` using the same image and a command override, with the **admin** credentials injected from the RDS-managed secret. Real-world pattern: "migrations run as a task before the deploy" | Claude |
| L1.4 | **Least privilege in the database:** the migration creates role `api_reader` with **SELECT only**; its password is generated by Terraform (`random_password`, lives in local git-ignored state), stored in Secrets Manager `station-stream-tf/db/api-reader`, and injected into the API container via the task definition's `secrets` (the **execution** role gets `secretsmanager:GetSecretValue` on that one secret). The API never sees the admin password | Claude writes, owner approves IAM |
| L1.5 | **API change** (`src/catalog.js` + `src/server.js`): if `DATABASE_URL`/`PG*` env is set, load the catalog from Aurora into the **same in-memory shape**; otherwise use the JSON (local dev, app 1). **Refresh on demand, stale-while-revalidate:** serve the cached copy immediately; if it's older than 60 s, refresh in the background. No traffic → no queries → **Aurora auto-pauses → $0 idle**. Keep `pg` pool `idleTimeoutMillis` short (e.g. 30 s) so idle connections don't keep it awake. If Aurora is unreachable, keep serving the last good copy; at boot, fall back to the bundled JSON. Add `CATALOG_CACHE=off` (env) for L2 run 4 | Claude |
| L1.6 | **`/health` must not depend on the database.** The ALB uses it to decide if a task is healthy; if it checked Aurora, a database blip would mark every task unhealthy → total outage (**cascading failure**). `/health` *reports* `catalogSource` (`aurora`/`json`) and `catalogAgeSeconds` but never fails because of them | Claude |
| L1.7 | **Ship it:** commit `src/**` → GitHub Actions image → copy to `station-stream-tf` → `var.image_tag` → apply. Show in the console: RDS → Databases (writer, ACU graph, "Paused"), Secrets Manager (two secrets), **Query Editor** (`SELECT count(*) FROM episodes`). Check the Firebase site (https://station-stream-2026.web.app) still loads both stations and likes still work | Claude |

**Done when:** `curl https://d1436kyrcdypmk.cloudfront.net/health` shows `"catalogSource":"aurora"`; the Firebase site loads from it; the Query Editor shows the seeded rows; after ~5 idle minutes the cluster shows as paused (ACU 0); `terraform plan` → No changes; breadcrumbs + HANDOFF updated; committed and pushed.

**Fallback if L1 runs past ~2.5 h:** stop at "cluster created + migrated + queried in the Query Editor" (that's presentable), skip L1.5–L1.7, and go to L2 against the JSON-backed API.

### Interview talking points L1 should produce
- Aurora Serverless v2 scales in **ACUs** (~2 GiB RAM each) in fine steps; can **auto-pause at 0 ACU** (resume ~15 s); you pay per ACU-second plus storage and I/O.
- **Private database, SG-to-SG rule**, secrets in Secrets Manager injected by ECS, separate **read-only** app user.
- **Cache-first design:** the catalog changes rarely, so database load is independent of viewer count, and the DB can sleep when nobody watches.
- **Health checks that don't cascade.**
- What **RDS Proxy** adds (connection pooling for bursty clients like Lambda), why we don't need it with a few long-lived ECS tasks.
- Where an **ORM** like Prisma fits, and why plain SQL was fine here.

---

## L2: Traffic spike, then back to normal (~1.5 h)

**Goal:** show what happens when a station's audience multiplies in a minute, fix what breaks, watch it scale back down, and get a **per-task capacity number** for capacity planning.

### Expected weak points (stated up front, as hypotheses)
1. **Max 2 tasks, CPU-based, 300 s cooldowns.** CloudWatch needs ~3 one-minute datapoints before scaling out, and a Fargate task needs ~1 minute to start, so a 30-second spike is under-served for 3–5 minutes.
2. **Likes function:** max 2 instances × concurrency 1 → throttles fast; Atlas M0 has its own ops/sec limits. (Test it lightly or leave it out of the load script. Not the focus.)
3. **Video is not the risk:** HLS comes from CloudFront/S3. (At Local Public, video comes from PBS's CDN, so for them too the spike risk is the API.)

### Tool
**k6** (Grafana) via **Docker** (`grafana/k6`, pin a version), script in `loadtest/spike.js` (committed). It requests the **same GraphQL `Home` query the page uses** (copy it from `public/index.html`) for both stations, plus `/health`, through `https://d1436kyrcdypmk.cloudfront.net`. Use k6 thresholds (e.g. `http_req_failed < 1%`, `p(95) < 800ms`) so each run says pass/fail.

### Load profile (VUs = virtual users)
```
 300 |          ┌──────────┐
     |         /            \
  10 |────────┘              └──────────────────────
     0   2m  2.5m        7.5m 8m                  18m
     baseline  spike: 30 s ramp, 5 min hold   back to normal (watch scale-in)
```

### Runs
| Run | Config | Purpose |
|---|---|---|
| 1. Baseline | today's config, 10 VUs × 5 min | normal p50/p95/p99 latency, error rate, **requests/s one task handles** |
| 2. Spike, as-is | today's autoscaling (max 2, CPU, 300 s) | the evidence: expect latency and errors while autoscaling lags |
| 3. Spike, tuned | max **6**; target tracking on **`ALBRequestCountPerTarget`** (reacts before CPU does; target derived from run 1); scale-out cooldown **60 s**, scale-in stays slow (300 s+) so it doesn't flap; optional **CloudFront 30 s cache for GraphQL GET** requests (needs a GET-capable query path; skip if it gets complicated) | compare against run 2 |
| 4. Optional: cache off | `CATALOG_CACHE=off`, moderate spike | watch **Aurora Serverless v2 scale ACUs** under load, and why the cache matters |

### What to watch (and screenshot into the breadcrumbs)
- k6 summary: req/s, p50/p95/p99, failure %.
- CloudWatch: ECS `CPUUtilization`, `RunningTaskCount`; ALB `TargetResponseTime`, `HTTPCode_Target_5XX_Count`, `RequestCountPerTarget`; ECS service **events** and Application Auto Scaling **activity history** (`aws application-autoscaling describe-scaling-activities`); Aurora `ServerlessDatabaseCapacity` (ACU) and `DatabaseConnections`.
- GCP: the G5 uptime check (latency; the alert email may fire in run 2, which is a real end-to-end alert demo).
- After the spike: tasks scale back in to 1 (takes a while: that's the slow scale-in), ACUs drop, Aurora eventually pauses.

### Capacity-planning output (write it down)
`one 0.25 vCPU task ≈ N req/s at p95 < X ms` (from run 1/3) → for a peak of P req/s you need ⌈P / N⌉ tasks + 30–50 % headroom. Also: **scheduled scaling** for known events (pledge drives, election night, a premiere) beats reactive scaling; caching is the cheapest capacity.

**Safety:** only hit our own endpoints (CloudFront `d1436…` → app 2). Never PBS, jsDelivr or other third parties. Peaks of a few hundred req/s are normal use for AWS. After L2, **put the tuned autoscaling into Terraform permanently** (or revert, owner's choice) so `terraform plan` shows No changes.

**Done when:** all runs logged with numbers, the before/after comparison and the capacity-planning line are in the breadcrumbs, autoscaling config is in Terraform, and everything is back to 1 task.

---

## Costs (warn before creating)

| Item | Cost |
|---|---|
| Aurora Serverless v2 | ~$0.12 per ACU-hour in us-east-1 *(verify)*. **$0 while auto-paused**; ~$0.06/h at 0.5 ACU; up to ~$0.48/h at 4 ACU during run 4. Storage ~$0.10/GB-month (tiny), I/O ~$0.20 per million requests |
| Extra Fargate tasks in L2 | ~$0.01/h each (ARM, 0.25 vCPU / 0.5 GB); 6 tasks × 30 min ≈ pennies |
| CloudFront + ALB during L2 | a few hundred thousand requests ≈ < $1 |
| Secrets Manager | $0.40/secret/month (2 secrets) |

**Teardown reminder for the owner** (after the interview): Aurora is the first thing to remove if the project is parked: `terraform destroy -target=aws_rds_cluster_instance.… -target=aws_rds_cluster.…` or a full `terraform destroy`.

## Wrap-up for the session
- Update [HANDOFF.md](HANDOFF.md) (state table, what's done), both breadcrumb files, and add an "Aurora Serverless v2" + "Load testing and capacity planning" section to [STUDY_GUIDE.md](STUDY_GUIDE.md) in the same plain-English style.
- End with 2–3 interview sentences for L1 and for L2.
