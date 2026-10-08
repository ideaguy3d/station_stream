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
