# Interview Prep: Local Public, Systems Reliability Engineer

Interview: 2026-10-06 | Pay $100k-$110k | Remote US | Start Nov 2 | Core hours 9am-1pm PT, plus afternoon/evening coverage

## 60-minute plan

| Min | Do |
|---|---|
| 0-5 | Read "Company" + memorize the 60-sec pitch out loud twice |
| 5-20 | Rehearse the 5 stories out loud (2 min each max) |
| 20-40 | Crash sheet: ECS, CloudFront, Aurora Serverless, Terraform, GitHub Actions, streaming |
| 40-50 | Answer the "likely questions" out loud, especially the gap question |
| 50-60 | Pick 4 questions to ask, test camera/mic, open your resume + this sheet |

## Company (say this back to them)

- Spun out of Cascade PBS (Seattle) as a Delaware public benefit corporation, May 2026. Wholly owned by Cascade PBS.
- CEO/President: Kevin Colligan (ex VP Media & Innovation, Cascade PBS).
- Product: white-label, locally branded streaming apps for PBS member stations on connected TV, web, mobile (Apple, Google, Roku, LG, Samsung).
- 18 stations live; goal 30+ soon, all public TV stations in 3 years. Rocky Mountain PBS is an early adopter.
- Results: +53% contributions, +30% new supporters for stations. Pricing for small stations: $8k onboarding + $60k/yr.
- Why it matters now: federal CPB funding ended in 2025, so stations need their own donor revenue. Local Public apps are a revenue engine, so uptime = station donations.
- Implication for you: multi-tenant platform. Every new station adds load, config and release surface. Reliability must scale per station without scaling headcount.

## 60-sec pitch

"I'm an engineer who owns production systems end to end. At Apple's AI/ML group for 4+ years I owned monitoring and maintenance of a production video similarity system running across 40+ labs in the US and China on AWS, plus PySpark/Airflow pipelines on EMR and capacity forecasting. Before that I rebuilt a high-volume download system with concurrent non-blocking I/O, 24 minutes down to 2, scaling from 100k to 500k+ downloads a month. Right now I run career.ranklab.org, a production AI app on Databricks serverless model serving, where I built OAuth token reuse, bounded concurrency and request tracing. I want this role because a small team means I own uptime and releases, and your uptime directly drives station donations."

## Your 5 stories (STAR, 2 min each)

1. **Monitoring/ownership (Apple):** Video similarity system across 40+ labs. Packaged Python modules, deployed via SSH + cron, owned monitoring and fixes. Result: high reliability, thousands of labeling hours saved. Maps to: System Health & Monitoring.
2. **Performance/scaling (Mhetadata):** Image download platform. Sequential I/O was the bottleneck; switched to concurrent non-blocking I/O + batch scheduling. 24 min to 2 min per 2,000 images; 100k to 500k+ monthly; 45-min manual job to <4 min automated. Maps to: Scalability & Performance.
3. **Throughput (Apple):** ETL refactor from single to multi-processing, added logging + SQL analytics. Maps to: bottleneck resolution.
4. **Capacity planning (Apple):** Forecast data growth to plan infrastructure; improved efficiency; dashboards for leadership. Maps to: autoscaling, cost, communicating technical updates.
5. **Protecting a backend under load (career.ranklab.org):** Serverless endpoint behind PHP. OAuth client-credentials with token reuse (no auth call per request), bounded concurrency so bursts can't overwhelm the endpoint, structured response parsing, MLflow tracing on every request. Maps to: serverless backends, observability, graceful degradation.

Have one **failure story** ready: an outage or bug you caused or caught, what broke, how you found it, what you changed so it can't recur. Pick a real one from Apple or Redstone before the call.

## The gap question (they WILL ask)

Gaps: ECS, Terraform, GitHub Actions in production, Aurora, CloudFront, GraphQL, app-store releases.

Answer: "I haven't run ECS or Terraform in production yet. What I have done is the underlying work: deploying and monitoring distributed workloads across 40+ sites, scaling pipelines on AWS EMR, and running a serverless production app. ECS is the managed version of what I did by hand with SSH and cron, and Terraform is the codified version of the infra I provisioned. I pick up stacks fast: PHP/SQL Server at Redstone, PySpark/Airflow at Apple, Databricks serving this year, certified in August. In the first 30 days I'd map your Terraform state and pipelines, then own the deploy path."

Do not bluff details. Say "I'd verify that in your setup" when unsure.

## Crash sheet (know the vocabulary)

**SRE basics**
- SLI (measured: availability, latency, error rate), SLO (target, e.g. 99.9%), error budget (allowed failure; spend it on releases).
- Golden signals: latency, traffic, errors, saturation.
- Incident flow: detect, triage (scope + blast radius), mitigate first (rollback, failover, scale), then root cause, blameless postmortem, action items.
- Alert on symptoms users feel (error rate, playback failures), not every CPU spike. Avoid alert fatigue.

**Streaming specifics**
- HLS (Apple) / DASH: video split into short segments + manifest (.m3u8). Players fetch segments over HTTP, so the CDN does most of the work.
- Key viewer metrics: video start time, video start failures, rebuffer ratio, bitrate, crash rate.
- CDN: cache-hit ratio (higher = less origin load), TTLs (segments long, live manifests short), origin shield, cache invalidation, signed URLs/cookies for protected content.
- Likely: video itself comes from PBS/partners; Local Public serves app shell, catalog/metadata API (GraphQL), auth, donations. Ask them.

**AWS**
- ECS: task definition (container spec) -> service (keeps N tasks running) -> cluster. Fargate = serverless containers. Behind an ALB. Rolling or blue/green deploys. Service auto scaling with target tracking (e.g. CPU 60%, or requests per target).
- CloudFront: distributions, behaviors per path, origins (S3/ALB), Origin Access Control for S3, invalidations, WAF in front.
- Aurora Serverless v2: Postgres/MySQL-compatible, scales in ACUs (capacity units) between min/max. Watch: connection limits (use RDS Proxy), min ACU set too low causes slow ramp in a spike.
- Secrets Manager / Parameter Store, IAM least privilege, CloudWatch metrics/alarms/logs.

**GCP / Firebase**
- Cloud Functions (gen 2 runs on Cloud Run): cold starts; fix with min instances. Concurrency settings.
- Cloud Build: triggers on git push, build steps in cloudbuild.yaml.
- Firebase: Hosting, Auth, Firestore, Remote Config (feature flags without app-store release), Crashlytics.

**IaC + CI/CD**
- Terraform: write HCL -> `plan` (diff) -> `apply`. Remote state (S3 + DynamoDB lock), modules for reuse, drift = reality differs from code.
- FlightControl: PaaS layer that deploys to your own AWS account (ECS under the hood).
- GitHub Actions: workflows on push/PR, jobs, environments with required approvals, OIDC to assume AWS roles (no long-lived keys), cache dependencies.
- Low-risk releases: small changes, automated tests, canary or blue/green, feature flags, one-click rollback.

**Data/API**
- Postgres: indexes, EXPLAIN ANALYZE, slow query log, connection pooling, read replicas.
- MongoDB serverless = Atlas serverless; watch indexes and connection churn from functions.
- GraphQL: N+1 queries (fix with DataLoader batching), query depth/complexity limits, cache at resolver or CDN with persisted queries.
- ORM: watch generated N+1 queries and missing indexes.

**App store releases**
- Apple: TestFlight, App Review, phased release. Google Play: staged rollout %. Roku: channel certification. Samsung (Tizen), LG (webOS): store review with lead time.
- Ops angle: review lead times differ, so ship risky changes behind Remote Config flags and coordinate a release calendar with product.

## Likely questions + skeleton answers

1. **"A station's app is down at 7pm during a pledge drive. Walk me through it."** Confirm scope (one station, one platform, or all?) via dashboards/status. Check recent deploys first; roll back if correlated. Check CDN, API error rates, DB connections/ACU, function errors. Mitigate, communicate status to stakeholders every 15-30 min, then postmortem.
2. **"Traffic spikes 10x when a big show airs. How do you prepare?"** Pre-scale (raise ECS min tasks, Aurora min ACU, function min instances) before known events, load test, maximize CDN cache-hit, rate-limit/bounded concurrency on backend, alerts on saturation.
3. **"How would you set up monitoring from scratch?"** Define SLOs per user journey (app launch, browse, play, donate). Instrument golden signals, synthetic checks per station app, client crash/playback metrics, centralized logs, paging only on SLO burn.
4. **"How do you make deploys low risk?"** Story 5 + CI tests, staged rollouts, flags, automatic rollback.
5. **"Multi-cloud: why, and what's hard?"** Hard: two IAM models, two monitoring stacks, networking/egress cost. Fix: one IaC repo, one alerting destination, consistent tagging.
6. **"Security?"** Least-privilege IAM, OIDC for CI, secrets manager, dependency scanning, WAF, patching, audit logs.
7. **"Hours?"** Confirm you're on PT (Lathrop, CA) and fine with core 9-1 PT plus afternoon/evening coverage. Ask how on-call is shared.
8. **"Salary?"** "The posted $100k-$110k works for me." Don't go below it.
9. **"Why Local Public?"** Mission + ownership: public media funding shifted to stations, your apps raise their donations, and a small team means you own reliability end to end.

## Questions to ask them (pick 4)

1. What does the current stack look like end to end: how much is ECS vs FlightControl vs Firebase, and is Terraform the source of truth?
2. What were the last 2-3 incidents, and what's monitoring/alerting today?
3. How does onboarding a new station work technically: config, separate deploys, or one multi-tenant platform?
4. Scaling from 18 to 30+ stations: what breaks first?
5. How is on-call and evening coverage shared on the team?
6. What would success look like at 90 days?
7. Who serves the video itself: your CDN or PBS/partner infrastructure?

## Logistics checklist

- Tailored resume data: `skills/create_cv/json/Local_Public-Systems_Reliability_Engineer-7d122619375b4a6485c641166c65d3af_1.json` (PDF not in repo; use the copy you submitted. Note: it says "unemployed" for Rank Lab; frame as "building production systems full time between roles").
- Cover letter already admits the ECS/Terraform/GitHub Actions gap; stay consistent with it.
- Camera, mic, quiet room, water, this sheet on a second screen.
- Close with: "Is there anything about my background that gives you pause?" Then answer it.

Sources: [Current](https://current.org/2026/07/cascade-pbs-spins-off-local-public-into-separate-entity/), [GeekWire](https://www.geekwire.com/2026/seattles-cascade-pbs-spins-out-local-public-a-tech-platform-that-builds-streaming-apps-for-stations/), [posting](https://www.idealist.org/en/consultant-job/7d122619375b4a6485c641166c65d3af-systems-reliability-engineer-local-public-a-public-benefit-corporation-seattle)
