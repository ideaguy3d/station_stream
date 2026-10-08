# Station Stream: instructions for Claude

> **Starting a new session? Read [docs/HANDOFF.md](docs/HANDOFF.md) first:** current state of both AWS apps and the agreed plan for the GCP version.

This is a learning project. The owner is preparing for a Systems Reliability Engineer interview and is new to ECS, CloudFront, Terraform and GitHub Actions. **Learning matters more than speed.** The AWS part is the most important part.

## AWS work: console first, then log it

1. **Drive the AWS console in the built-in browser** (`mcp__Claude_Browser__*`) to create or change AWS resources, explaining each screen and field as you go. The owner learns by watching. Don't silently do AWS work from the CLI.
   - The CLI is fine for read-only checks (describe/list/get), verification, and bulk or repetitive work. Say what you're doing and why.
   - IAM permission-granting clicks are blocked for Claude. Hand those to the owner with exact click steps.
2. **Record every AWS command in [docs/aws-breadcrumbs.md](docs/aws-breadcrumbs.md)**: commands already run, commands for console actions you took, and planned ones. Each entry has:
   - **What & why**: what the piece is and why it exists
   - **CLI**: the exact command, with comments on the important flags
   - **Console**: the click path for the same action
   - **Check**: a command that proves it worked
   - Status: ✅ done · ❌→✅ failed first (keep the real error message and how it was diagnosed) · 🔜 planned
3. Update the breadcrumbs file **in the same step** as the AWS change, not at the end of a phase.
4. Before each AWS step, explain in 2–3 plain sentences what the piece is and why it exists.

## AWS environment

- Always `export AWS_PROFILE=station-stream AWS_REGION=us-east-1`. The profile is the limited IAM user `station-stream-dev`. Never use root keys; root has none.
- The IAM user can only create roles named `station-stream-*` (see [infra/iam/builder-iam-scoped.json](infra/iam/builder-iam-scoped.json)).
- Tag every resource `project=station-stream` so teardown can find it.
- **Warn before anything that bills by the hour** and give the cost. Use the smallest sizes (Fargate ARM64, 0.25 vCPU / 512 MB, 1 task). No NAT gateway.
- The shell is **zsh**: unquoted `$VAR` is not split on spaces. Pass multiple values (such as subnet IDs) as separate words.
- Resource IDs are listed at the top of `docs/aws-breadcrumbs.md`.

## GCP environment

- Always `export CLOUDSDK_ACTIVE_CONFIG_NAME=station-stream` (gcloud's version of `AWS_PROFILE`): project `station-stream-2026`, region `us-central1`. gcloud lives in `~/google-cloud-sdk` (`source ~/google-cloud-sdk/path.zsh.inc` in non-interactive shells). Don't touch the `default` configuration; it belongs to the owner's other work.
- Log every GCP step in [docs/gcp-breadcrumbs.md](docs/gcp-breadcrumbs.md), same format and rules as AWS.

## How to work with the owner

- Plain English. Explain every acronym or AWS term in one sentence the first time it appears.
- Work in the phases from the plan. **Stop after each phase**, summarize what was built, and wait for "go".
- When something fails (especially IAM, VPC and security groups), explain the error and how you diagnosed it. Those are the interview stories.
- End each phase with 1–2 interview sentences: what was built and the hardest problem solved.

## Code and git

- Never put secrets in code or git. `.gitignore` covers `.env*`, keys, tfstate and video.
- UI is styled with **Tailwind CSS v4**, built with `@tailwindcss/cli` (`npm run build:css`), not the Play CDN.
- Commit messages: **one short subject line** plus the co-author trailer. No body or essay.
- **Push to `origin main` automatically after each commit.** Standing permission; no need to ask.
- Don't stage the owner's unrelated changes (for example, deleted PDFs).

## Project layout

- `src/`: Node.js + Apollo GraphQL API (`/graphql`, `/health`)
- `public/`: player page (hls.js + Tailwind)
- `data/`: catalog shaped like PBS Media Manager, plus station themes
- `scripts/`: ffmpeg HLS encoding and the local CDN stand-in (port 8080)
- `infra/`: IAM policies, ECS task definition (Terraform comes in Phase 9)
- `npm run dev`: API on :4000 + local CDN on :8080 + Tailwind watcher
