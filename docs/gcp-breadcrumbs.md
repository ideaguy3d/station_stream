# GCP breadcrumbs: every command, in order, explained

The GCP half of the project: web UI on Firebase Hosting, a Cloud Run function for "likes", Cloud Build for deploys, all talking to the AWS API (app 2). Plan: [HANDOFF.md](HANDOFF.md) section 4.

For each step:

- **What & why**: what the piece is and why it exists
- **CLI**: the exact command that was run (or will be run)
- **Console**: the same thing done by clicking
- **Check**: a command that proves it worked

Status markers: ✅ done · ❌ failed first (the error and the fix are the interview story) · 🔜 planned

> Every command assumes the `station-stream` gcloud **configuration** (GCP's version of an AWS CLI profile, see G0.6):
> ```bash
> export CLOUDSDK_ACTIVE_CONFIG_NAME=station-stream   # like AWS_PROFILE: this account + project + region
> ```

## Resource IDs (not secrets, just names)

| Name | Value |
|---|---|
| Project | name `station-stream`, ID `station-stream-2026`, number `203966301167` (no organization) |
| Region | `us-central1` (Cloud Run / functions; Atlas M0 on GCP lives there too) |
| gcloud configuration | `station-stream` (account juliushernandezalvarado@gmail.com) |
| Billing account | `015DB1-CF4577-626C05` ("My Billing Account", free trial, $300, expires 2027-01-06) |
| Auto-created org (not used) | `juliushernandezalvarado-org` (`678324810952`), holds "My First Project" |

---

## G0: Setup

### G0.0 Identity: there is no root user or IAM user in GCP

**What & why:** in AWS we avoided root by working as the scoped IAM user `station-stream-dev`. GCP has neither. A person is a **Google account**; the account that creates a project gets the **Owner** role on it, which is an ordinary, revocable role binding. So humans use their own Google identity (with 2-Step Verification on), and least privilege is applied to **service accounts**, the identities that code runs as. No service-account JSON key files (the GCP version of long-lived access keys): the CLI uses `gcloud auth login`, and outside systems use **Workload Identity Federation** (keyless, like the GitHub OIDC role on AWS).

### G0.1 ✅ Project `station-stream-2026`

**What & why:** a **project** is the GCP version of an AWS account: every resource, API switch, permission and charge belongs to one. It has a **display name** (a label, changeable) and a **project ID** (permanent, globally unique, used in every command and URL).

**Surprise:** new free-trial sign-ups now get an **Organization** created automatically (`juliushernandezalvarado-org`, holding "My First Project"). New orgs come with "secure by default" **org policies** (rules inherited by every project under the org). One of them, *domain-restricted sharing*, blocks granting roles to `allUsers`, which our public "likes" function will need. So our project stays under **No organization**. At a company, guardrails like that live at the org level and a project asks for an exception.

```bash
# --name is the label; the positional argument is the permanent project ID
gcloud projects create station-stream-2026 --name=station-stream
```

**Console:** project picker (top bar) → New Project → Project name `station-stream` → Project ID → Edit → `station-stream-2026` → Organization: No organization → Create.

**Check:**
```bash
gcloud projects describe station-stream-2026 --format='value(projectId,lifecycleState,parent)'
# station-stream-2026  ACTIVE  (empty parent = no organization)
```

### G0.2 ✅ Billing account linked

**What & why:** a **billing account** (who pays) is separate from a **project** (where things run). A project must be linked to one before any paid API can be enabled. The free-trial billing account was linked to the new project automatically.

```bash
# What would link it if it weren't already
gcloud billing projects link station-stream-2026 --billing-account=015DB1-CF4577-626C05
```

**Console:** Billing → (project selected) → shows "My Billing Account", Free trial account.

**Check:**
```bash
gcloud billing projects describe station-stream-2026 --format='value(billingAccountName,billingEnabled)'
# billingAccounts/015DB1-CF4577-626C05  True
```

### G0.3 ✅ $10 monthly budget that ignores the trial credit

**What & why:** a budget emails you when spend crosses thresholds. It never stops anything. Same trap as AWS 0.1: by default a GCP budget subtracts **all** credits, including the $300 free-trial credit (type *Promotional credits*), so it would sit at $0 and never fire. We untick only **Promotional credits**. **Free tier credits** stay ticked: those are permanent free allowances, so subtracting them is honest.

Choices on the form:
- Type **Alerts only**. The other choice, *Spend cap enforcement* (Preview), really pauses usage but only for a few services. Not something to rely on.
- Scope **All projects** (both projects draw on the same $300 and then the same card).
- Thresholds **50 / 90 / 100 % actual + 100 % forecasted** (forecast fires early, when Google predicts you'll cross $10).
- Not used: **Pub/Sub topic**. Budget messages to a topic can trigger a function that unlinks billing: the do-it-yourself hard cap.

```bash
# Every credit type EXCEPT PROMOTION (the free trial) is subtracted
gcloud billing budgets create \
  --billing-account=015DB1-CF4577-626C05 \
  --display-name=station-stream-gcp-10usd \
  --budget-amount=10USD \
  --calendar-period=month \
  --credit-types-treatment=include-specified-credits \
  --credit-types=FREE_TIER,SUSTAINED_USAGE_DISCOUNT,DISCOUNT,COMMITTED_USAGE_DISCOUNT,COMMITTED_USAGE_DISCOUNT_DOLLAR_BASE,SUBSCRIPTION_BENEFIT,OTHER \
  --threshold-rule=percent=0.5 \
  --threshold-rule=percent=0.9 \
  --threshold-rule=percent=1.0 \
  --threshold-rule=percent=1.0,basis=forecasted-spend
```

**Console:** Billing → Budgets & caps → Create → Alerts only → Name → Next → Scope: Monthly, All projects, All services, Savings → expand *Other savings* → untick **Promotional credits** → Next → Amount: Specified amount, 10 → Next → Actions: keep 50/90/100, Add threshold → 100 % **Forecasted** (the "Percentage must be unique" error clears once the trigger differs) → keep "Email alerts to billing admins and users" → Finish.

**Check:**
```bash
gcloud billing budgets list --billing-account=015DB1-CF4577-626C05 \
  --format='table(displayName,amount.specifiedAmount.units,budgetFilter.creditTypesTreatment,budgetFilter.creditTypes.list())'
# station-stream-gcp-10usd  10  INCLUDE_SPECIFIED_CREDITS  OTHER,SUSTAINED_USAGE_DISCOUNT,...,FREE_TIER,...  (no PROMOTION)
# (needs billingbudgets.googleapis.com enabled, done in G0.5)
```

### G0.4 ❌→✅ Install the CLIs: `gcloud` and `firebase`

**What & why:** `gcloud` is GCP's version of the `aws` CLI. `firebase` (npm package `firebase-tools`) deploys Firebase Hosting and manages Firebase projects. Both live on your Mac only.

```bash
npm install -g firebase-tools        # ✅ firebase 15.33.0
brew install --cask gcloud-cli       # ❌ (cask was renamed from google-cloud-sdk)
```

**What failed:** the cask depends on `python@3.14`. On macOS 14, Homebrew has no prebuilt bottles ("Tier 3"), so it compiles Python and its libraries from source. Twice it died while building `expat` with `RuntimeError: Will not overwrite ~/Library/Caches/Homebrew/api/internal/executables.txt`. **Fix:** Google's own installer instead of Homebrew. The owner downloaded `google-cloud-cli-darwin-arm.tar.gz` (54 MB, dl.google.com) and unpacked it to `~/google-cloud-sdk`, then:

```bash
# Adds gcloud to PATH + tab completion in ~/.zshrc; no anonymous usage stats
~/google-cloud-sdk/install.sh --quiet --usage-reporting=false --path-update=true \
  --command-completion=true --rc-path="$HOME/.zshrc"
```

It also tried an *optional* system-wide Python 3.14 install that needs `sudo` (your Mac password) and failed without a terminal. Harmless: gcloud runs fine on the existing Python 3.12.8 inside its own virtualenv (`gcloud info` shows it).

**Check:**
```bash
gcloud --version && firebase --version
```

### G0.5 ✅ Enable APIs

**What & why:** every GCP service is an **API** that starts **off** in a new project; calling a disabled one fails with `SERVICE_DISABLED`. Enabling is free (you pay for usage), and keeping the list short limits what a leaked credential could touch. AWS has no equivalent: all services are always on. Enabling an API also enables what it depends on: turning on Cloud Run brought along Artifact Registry, Pub/Sub and Cloud Storage. A new project already has Logging, Monitoring, BigQuery and a few more on by default.

```bash
# run              ✅ (console) Cloud Run: runs the function's container
# cloudfunctions   Cloud Run functions (the "deploy from source" front door)
# cloudbuild       builds function source into a container image
# artifactregistry stores those images (GCP's ECR); already on via Cloud Run
# secretmanager    Atlas connection string
# firebase         Firebase management · firebasehosting: web UI · identitytoolkit: Firebase Auth
# logging, monitoring: already on by default
gcloud services enable run.googleapis.com cloudfunctions.googleapis.com \
  cloudbuild.googleapis.com artifactregistry.googleapis.com secretmanager.googleapis.com \
  firebase.googleapis.com firebasehosting.googleapis.com identitytoolkit.googleapis.com \
  logging.googleapis.com monitoring.googleapis.com billingbudgets.googleapis.com
# billingbudgets: lets the CLI read the budget (G0.3 check). Took ~12 s total.
```

**Console:** APIs & Services → Library → search the API → Enable (project picker must show `station-stream`).

**Check:**
```bash
gcloud services list --enabled --format='value(config.name)' | sort
```

### G0.6 ✅ Sign the CLI in, in its own named configuration

**What & why:** `gcloud auth login` signs the CLI in **as you** with OAuth 2.0: the browser approves, Google redirects to a tiny server gcloud runs on `localhost:8085`, and **PKCE** (`code_challenge … S256`) means an intercepted approval is useless without gcloud's secret. A refresh token is stored in `~/.config/gcloud`; no key file.

**Surprise:** this Mac already had gcloud settings from older work (account `julius.data.analyst@gmail.com`, project `j-data1`), and logging in silently repointed that shared **default** configuration. Mixing like that is how commands hit the wrong project. Fix: a **named configuration**, GCP's version of an AWS CLI profile, selected per shell with an environment variable. The old default was put back.

```bash
gcloud auth login   # run by the owner in the Terminal tab; browser approval
gcloud config configurations create station-stream --no-activate
C=--configuration=station-stream
gcloud config set account juliushernandezalvarado@gmail.com $C
gcloud config set project station-stream-2026 $C
gcloud config set run/region us-central1 $C
gcloud config set functions/region us-central1 $C
# restore the pre-existing default configuration
gcloud config set project j-data1 --configuration=default
gcloud config set account julius.data.analyst@gmail.com --configuration=default

export CLOUDSDK_ACTIVE_CONFIG_NAME=station-stream   # per shell, like AWS_PROFILE
```

**Check:**
```bash
gcloud config configurations list   # station-stream: our account + project; default: untouched
```

### G0.7 ⚠️ Finding: default service accounts got `Editor`

**What & why:** enabling the APIs created two **default service accounts** and Google granted both **`roles/editor`** (change almost anything in the project):

- `203966301167-compute@developer.gserviceaccount.com`: the **default compute SA**. Cloud Run functions *run* as it, and on new projects also *build* with it, unless you name another account.
- `station-stream-2026@appspot.gserviceaccount.com`: App Engine default (unused).

Inside an Organization, the secure-by-default org policy `iam.automaticIamGrantsForDefaultServiceAccounts` stops this. Our project is outside the org, so it got the legacy behavior: anything deployed without an explicit identity runs with near-total control of the project. **Plan (G3/G4):** dedicated least-privilege service accounts (`likes-fn` runtime, a build account), then remove `Editor` from the defaults. Not now: stripping it before a dedicated build account exists can break the first function build.

**Check:**
```bash
gcloud projects get-iam-policy station-stream-2026 --flatten='bindings[].members' \
  --filter='bindings.role=roles/editor' --format='value(bindings.members)'
```

### G0.8 ✅ Add Firebase to the project (Blaze plan)

**What & why:** Firebase is not a separate cloud. It's a developer-friendly layer **on top of a GCP project**: Hosting, Auth, Cloud Messaging and the rest bill, log and live in `station-stream-2026`. We added it to the existing project instead of letting Firebase create a second one. Because the project already had billing linked, it landed on the **Blaze** (pay-as-you-go) plan automatically, which Cloud Run functions require. The owner accepted the Firebase terms (a click Claude doesn't make).

What it created:
- Default **Hosting site** `station-stream-2026` → **https://station-stream-2026.web.app** (also `station-stream-2026.firebaseapp.com`). This is the origin the AWS API must allow via **CORS** in G1.
- **Google Analytics** link: property `558099719` in a new Analytics account `411240459` (on by default in the setup flow). Free, and it only collects data if the page loads the Analytics SDK. Kept: it matches Local Public's "first-party analytics".
- Google-managed **service agents** with narrow Firebase roles (`service-203966301167@gcp-sa-firebase…`, `firebase-adminsdk-fbsvc@…`). Nothing broad, unlike G0.7.

```bash
# CLI equivalent (needs `firebase login` first; terms must already be accepted)
firebase projects:addfirebase station-stream-2026
```

**Console:** console.firebase.google.com → Get started by setting up a Firebase project → *Already have a Google Cloud project?* **Add Firebase to Google Cloud project** → select `station-stream` → tick *I accept the Firebase terms* → Continue → (Analytics on by default) → done. Overview shows **Blaze plan · via Google Cloud Free Trial**.

**Check:**
```bash
T=$(gcloud auth print-access-token)
curl -s -H "Authorization: Bearer $T" -H "x-goog-user-project: station-stream-2026" \
  https://firebasehosting.googleapis.com/v1beta1/projects/station-stream-2026/sites
# "defaultUrl": "https://station-stream-2026.web.app"
```

**G0 done.** Next: G1, CloudFront in front of app 2's ALB + CORS for `https://station-stream-2026.web.app` (Terraform, AWS side).

---

## G2: Web UI on Firebase Hosting, calling the AWS API

### G2.1 ✅ Make the page's API address configurable (build-time config)

**What & why:** the page used to call `fetch('/graphql')`: same origin, because ECS served both page and API. On Firebase the API lives on another origin. So `public/index.html` now loads `/config.js` first and calls `${API_BASE}/graphql`:

- In the repo, `public/config.js` = `apiBase: ''` (same origin). ECS keeps working unchanged.
- The Firebase build writes its own `config.js` with the AWS API URL. Same page, environment-specific value injected at build time.
- The footer shows `API: <host>`, handy for demos.

`styles.css` is built by Tailwind and git-ignored, so Hosting needs a build step anyway: [scripts/build-hosting.sh](../scripts/build-hosting.sh) (`npm run build:hosting`) builds CSS, copies `public/` to `gcp/hosting-dist/` (git-ignored) and writes `config.js`. Cloud Build will run the same script in G4.

```bash
API_BASE=https://d1436kyrcdypmk.cloudfront.net npm run build:hosting
# Built gcp/hosting-dist with apiBase=https://d1436kyrcdypmk.cloudfront.net  (config.js, index.html, styles.css)
```

**Negative test (CORS doing its job):** served `gcp/hosting-dist` from `http://localhost:5055`, an origin **not** on the API's allowlist. The page showed "Could not load station" / **`Failed to fetch`**. Browsers deliberately hide the CORS reason from page code (it only shows in DevTools), so a hostile page can't probe other servers through error messages.

### G2.2 ✅ Firebase config in `gcp/`

```jsonc
// gcp/firebase.json
{ "hosting": { "public": "hosting-dist", "ignore": ["firebase.json", "**/.*"],
  "headers": [{ "source": "**", "headers": [{ "key": "Cache-Control", "value": "no-cache" }] }] } }
// gcp/.firebaserc
{ "projects": { "default": "station-stream-2026" } }
```

`no-cache` = "browsers may keep a copy but must ask first" (a cheap `304 Not Modified` via ETag), so a new deploy shows up immediately. `.github/workflows/deploy.yml` now also ignores `gcp/**` and `scripts/build-hosting.sh`, so GCP-only commits don't redeploy AWS app 1.

### G2.3 ✅ Firebase CLI login

**What & why:** `firebase` keeps its own credentials (separate from gcloud's), so it needs its own OAuth login (localhost redirect on port 9005, scopes `firebase` + `cloud-platform`). Answered **No** to "Enable Gemini in Firebase" and to usage reporting. G4 (Cloud Build) will deploy as a service account instead, with no personal login.

```bash
firebase login            # owner, in the Terminal tab; browser approval
firebase projects:list    # station-stream │ station-stream-2026 │ 203966301167
```

### G2.4 ✅ Deploy

**What & why:** `firebase deploy --only hosting` uploads only changed files (content-hashed), **finalizes a version** and **releases** it: Hosting's version of a task-definition revision + service update. Every release is kept, so rollback is one click (Hosting → Release history → Roll back) or `firebase hosting:rollback`.

```bash
cd gcp && firebase deploy --only hosting --project station-stream-2026
# found 3 files in hosting-dist → version finalized → release complete
# Hosting URL: https://station-stream-2026.web.app
```

**Console:** Firebase console → Hosting → Release history (each deploy, who, when, file count).

**Check:**
```bash
curl -sI https://station-stream-2026.web.app/ | grep -i -E '^HTTP|cache-control|strict-transport|x-served-by'
# HTTP/2 200 · cache-control: no-cache · strict-transport-security … preload · x-served-by: cache-sjc… (CDN edge, San Jose)
curl -s https://station-stream-2026.web.app/config.js
# window.STATION_STREAM = { apiBase: 'https://d1436kyrcdypmk.cloudfront.net' };
```

**Result in the browser:** https://station-stream-2026.web.app/?station=north loads North Valley from the AWS API (8 episodes, 7 playable; footer `API: d1436kyrcdypmk.cloudfront.net`) and plays HLS at 720p from app 2's video CloudFront `d990usezj0kzv.cloudfront.net`. `https://station-stream-2026.firebaseapp.com/?station=south` loads Gulf Coast with its own theme. `http://` → `301` to `https://` (Firebase also sends **HSTS**: browsers will only ever use HTTPS for `web.app`).

**Cross-cloud path of one page view:** browser → Firebase Hosting CDN (GCP) for HTML/CSS/JS → CloudFront `d1436…` → ALB → ECS task (AWS) for GraphQL → CloudFront `d990…` → S3 (AWS) for video.

---

## G3: Liked videos: Firebase Auth + Cloud Run function + MongoDB Atlas

Mirrors Local Public's 3.0 "Liked Videos": a small per-user feature on the GCP side, while the catalog API stays on AWS.

```
browser (web.app) ── signInAnonymously ──▶ Firebase Auth ──▶ ID token (JWT)
        └── GET/POST + "Authorization: Bearer <token>" ──▶ Cloud Run function `likes` (runs as likes-fn)
                                                              ├─ verifyIdToken (Firebase Admin SDK)
                                                              ├─ MONGODB_URI ◀── Secret Manager `atlas-uri`
                                                              └─▶ MongoDB Atlas M0, GCP us-central1, db station_stream.likes
```

### G3.0 ❌→✅ MongoDB Atlas account: Marketplace vs direct

**❌ First try:** Atlas through **Google Cloud Marketplace** → *"This product cannot be purchased using a billing account currently associated with a free trial."* Marketplace bills third-party products through your Google billing account, and free-trial accounts can't buy Marketplace products. AWS Marketplace has the same rule.

**✅ Fix:** sign up **directly at mongodb.com**: Atlas bills you itself and the **M0** free cluster needs no card. You still pick "Google Cloud, us-central1": the cluster runs in MongoDB's own cloud account, so your GCP free trial isn't involved.

Result: `Cluster0`, MongoDB 8.0, **GCP / Iowa (us-central1)** (same region as the function), replica set of 3 nodes (primary + 2 secondaries, so a node failure doesn't take it down, even on the free tier).

**Security debts (fix after the interview):**
- The DB user `julius_db_user` has **atlasAdmin**. Least privilege = a separate app user with `readWrite@station_stream` only.
- The password was pasted into a chat transcript. Rotate it: Atlas → Database Users → Edit → **Autogenerate Secure Password** → Copy, then `pbpaste | gcloud secrets versions add atlas-uri --data-file=-` with the full new connection string, and redeploy the function (or point it at a pinned version). The old version can then be disabled: `gcloud secrets versions disable 1 --secret=atlas-uri`.

### G3.1 ✅ Atlas network access: `0.0.0.0/0` (owner's click)

**What & why:** Atlas only accepts connections from IPs on the project's **IP Access List**; auto-setup added only the owner's home IP. Cloud Run functions have **no fixed outgoing IP**. The proper fixes cost money or need a paid tier: **Cloud NAT with a static IP** (route egress through one address and allow just that), or **Private Endpoint / VPC peering** (not available on M0). So: allow `0.0.0.0/0` and rely on the other layers, **TLS** (always on with `mongodb+srv`) and a **strong password**. Claude's attempt to add it was blocked by its safety classifier ("security weaken"), correctly: it's the owner's call.

**Console:** Atlas → Database & Network Access → IP Access List → + ADD IP ADDRESS → `0.0.0.0/0`, comment `Cloud Run likes function (no fixed egress IP on free tier); TLS + password`, temporary **off** → Confirm.

**Diagnosis story:** before the entry existed, the deployed function failed with
```
MongoServerSelectionError: … SSL routines … tlsv1 alert internal error … SSL alert number 80
```
Not "IP not allowed": Atlas's front end **cuts off the TLS handshake** for addresses not on the list. The tell: the identical code and secret worked from the Mac (allowed IP) and failed from Cloud Run.

### G3.2 ✅ Connection string in Secret Manager

**What & why:** **Secret Manager** stores secrets encrypted, logs every read, and keeps numbered **versions** (rotation = add a version). The value went in through stdin, so it's in no file and no command history. The function gets it as an env var injected by Cloud Run at startup; it never appears in the deploy command or the function config.

```bash
printf '%s' "$ATLAS_URI" | gcloud secrets create atlas-uri \
  --replication-policy=automatic --labels=project=station-stream --data-file=-
```

**Check:** `gcloud secrets versions list atlas-uri` → `1  enabled`

### G3.3 ✅ Dedicated runtime service account `likes-fn` (least privilege)

**What & why:** the function runs as its own identity instead of the default compute SA (which has Editor, G0.7). Its only permission: **read one secret**, granted on the secret itself, not the project, so a future secret isn't readable by it.

```bash
gcloud iam service-accounts create likes-fn --display-name="likes function runtime (reads atlas-uri only)"
gcloud secrets add-iam-policy-binding atlas-uri \
  --member=serviceAccount:likes-fn@station-stream-2026.iam.gserviceaccount.com \
  --role=roles/secretmanager.secretAccessor
```

**Check:** `gcloud secrets get-iam-policy atlas-uri` → only `likes-fn` has `secretAccessor`.

### G3.4 ✅ Firebase Auth: anonymous sign-in + web app registration

**What & why:** each visitor silently gets a real Firebase user (stable `uid`, kept in the browser's IndexedDB across reloads), no login screen. The browser gets a signed **ID token** (a JWT) to send to the function. PBS stations log in with PBS Account, not Google, so Google sign-in wouldn't be more realistic. Anonymous accounts can later be linked to a real login.

**Console:** Firebase → Authentication → Get started → Sign-in method → **Anonymous** → Enable → Save. (Auto clean-up of 30-day-old anonymous accounts left off: it would orphan their likes.)

The page needs a **web app registration** for the Firebase JS SDK config. The Firebase **API key is not a secret**: it identifies the project and ships in every Firebase web page; access is controlled by Auth and our token check.

```bash
firebase apps:create WEB station-stream-web --project station-stream-2026
firebase apps:sdkconfig WEB 1:203966301167:web:1c64a346f8c7870d7eec1a
```

### G3.5 ✅ The function ([gcp/functions/likes/index.js](../gcp/functions/likes/index.js))

- `GET` → `{ likes: [episodeId…] }`, `POST { episodeId, liked }` → like/unlike. Every request needs `Authorization: Bearer <Firebase ID token>`; the `uid` comes **from the verified token, never from the body**.
- One `MongoClient` per instance, created on first use, reused (a connection per request is the classic serverless mistake); reset on failure so the next request retries.
- Unique index `{uid, episodeId}` + upsert = **idempotent**: liking twice is still one document.
- Input validated (`episodeId` must match `^[a-z0-9-]{1,64}$`, `liked` must be boolean).
- **Fail fast:** `serverSelectionTimeoutMS: 5000` (driver default 30 s) and a JSON **503** with a structured `ERROR` log, instead of a 30-second hang and a bare 500.
- Libraries: Functions Framework 5, firebase-admin 14, mongodb 7.

**Tested locally first** against the real Atlas cluster with a real anonymous token (Functions Framework is the same server Cloud Run uses):
```bash
MONGODB_URI="$(gcloud secrets versions access latest --secret=atlas-uri)" PROJECT_ID=station-stream-2026 \
  CORS_ORIGINS=https://station-stream-2026.web.app PORT=8090 npx functions-framework --target=likes
TOKEN=$(curl -s -X POST "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=$FIREBASE_API_KEY" \
  -H 'content-type: application/json' -d '{"returnSecureToken":true}' | jq -r .idToken)
# no token → 401 · bad token → 401 · like ×2 → one doc · list → ["ep-test-1"] · unlike → [] · bad body → 400 · preflight → 204
```

### G3.6 ❌→✅ Deploy

```bash
gcloud functions deploy likes --gen2 --region=us-central1 --runtime=nodejs22 \
  --source=gcp/functions/likes --entry-point=likes --trigger-http \
  --allow-unauthenticated \                                  # anyone may CALL it; the function checks the Firebase token itself
  --service-account=likes-fn@station-stream-2026.iam.gserviceaccount.com \   # not the default SA with Editor
  --set-secrets=MONGODB_URI=atlas-uri:latest \               # secret → env var at startup
  '--set-env-vars=^;^PROJECT_ID=station-stream-2026;CORS_ORIGINS=https://station-stream-2026.web.app,https://station-stream-2026.firebaseapp.com' \
  --max-instances=2 \                                        # caps cost and protects Atlas's 500-connection limit
  --memory=256Mi --update-labels=project=station-stream
```
(The inline `# comments` above are for reading; remove them to run it.)

**❌ First error:** `argument --set-env-vars: Bad syntax for dict arg: [https://station-stream-2026.firebaseapp.com]`. `--set-env-vars` splits on commas, so the second origin looked like a broken `KEY=VALUE`. **Fix:** gcloud's escape `^;^` switches that flag's separator to `;` (`gcloud topic escaping`).

**Result:** ACTIVE in 68 s. `--gen2` = a **Cloud Run function**: Cloud Build packs the source into a container, Cloud Run runs it, so there are two URLs for one thing:
- https://us-central1-station-stream-2026.cloudfunctions.net/likes
- https://likes-b5x7fos2oa-uc.a.run.app

Note `maxInstanceRequestConcurrency: 1`: under 1 CPU (we get 0.17), each instance takes one request at a time, so at most 2 in flight. Fine for a demo; production = 1 CPU + higher concurrency.

**Check:**
```bash
F=https://us-central1-station-stream-2026.cloudfunctions.net/likes
curl -s -w ' [%{http_code}]\n' $F
# {"error":"missing Authorization: Bearer <Firebase ID token>"} [401]  ← OUR 401 = allUsers may invoke.
# (Without --allow-unauthenticated, Google's front door would answer with an HTML 403 before our code ran.)
gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="likes"' --limit=10 --freshness=10m
```

### G3.7 ✅ Like buttons in the web UI

- [gcp/hosting-config.json](../gcp/hosting-config.json) (committed; public identifiers only): `apiBase`, `likesUrl`, Firebase web config. `npm run build:hosting` turns it into `config.js`.
- `public/index.html`: each episode card gets a ♡ button, **hidden by default**. A module script runs **only when `config.js` has `likesUrl` + `firebase`**: signs in anonymously, `GET`s likes, shows the hearts, and on click flips the heart **optimistically** (undoes it if the call fails). App 1 on ECS has no such config, so it never shows hearts: a feature flag through configuration.
- Firebase JS SDK pinned to **12.19.0** (a month old). 13.0.0 had been released the day before: not the day to adopt a new major version.

**Graceful degradation (seen live before G3.1):** hearts shown, the function verified the token, the database was unreachable → clean `503 likes are temporarily unavailable` after 5 s; the catalog and video kept working.

### G3.8 ✅ End to end, after the owner added `0.0.0.0/0`

The function retried by itself (the failed connection promise was reset), no redeploy needed:
```
list   {"likes":[]}                                 200  1.44 s   ← first request: TLS + find the primary + createIndex
like   {"episodeId":"ep-test-cloud","liked":true}   200  0.36 s   ← connection reused
list   {"likes":["ep-test-cloud"]}                  200  0.38 s
unlike {"episodeId":"ep-test-cloud","liked":false}  200  0.22 s
```
**In the browser:** like "Training the Machines" (♡ → ♥), **reload** → still ♥, the others ♡. Proves the chain: anonymous uid restored from IndexedDB → fresh ID token → function verifies it → MongoDB lookup by uid. The document is visible in Atlas → Data Explorer → `station_stream.likes` (`uid`, `episodeId`, `likedAt`).

**G3 done.** Next: G4, Cloud Build trigger on push to `main` that builds and deploys Hosting + the function as a least-privilege build service account.
