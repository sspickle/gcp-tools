# gcp-tools

CLI scripts for cost visibility and cleanup across a mixed portfolio of GCP projects.

## The idea

When you run a lot of GCP projects — some Cloud Run, some pure Firebase Hosting, some
both — the GCP console makes it awkward to get a quick answer to "what is this project
actually costing me in storage?"

These scripts give you that answer from the terminal, without opening a browser.
They auto-detect what's running in a project (by checking which APIs are enabled)
and query only the relevant services.

## Scripts

### `gcp-cost-report.sh` — per-project storage cost report

```bash
gcp-cost-report <project-id>
```

Auto-detects the project type and reports storage usage with estimated monthly costs:

| Project type | What gets checked |
|---|---|
| Firebase Hosting only | All sites → all release versions |
| Cloud Run / AR only | Artifact Registry image sizes per repo |
| Mixed | Both of the above |
| Any | Cloud Run service + revision count (informational; images billed via AR) |

Example output:
```
━━━ GCP Storage Cost Report: my-project ━━━

  Detecting enabled APIs... Firebase, Cloud Run/AR

  ▸ Firebase Hosting  ($0.026/GB/mo)
    my-site                               21 releases    12.52 MB  ~$0.00032/mo

  ▸ Artifact Registry  ($0.10/GB/mo)
    my-app (us-central1)                  15 images       2.30 GB  ~$0.23000/mo

  ▸ Cloud Run  (informational)
    my-app           us-central1           3 revisions

━━━ Summary: my-project ━━━
  Firebase Hosting:             12.52 MB  ~$0.00032/mo
  Artifact Registry:             2.30 GB  ~$0.23000/mo
  ──────────────────────────────────────────────────
  Total:                         2.31 GB  ~$0.23032/mo

  Rates: Firebase Hosting $0.026/GB, Artifact Registry $0.10/GB
  Excludes free tiers (10 GB Firebase, 0.5 GB AR/project/month) and egress
```

Pricing used: Firebase Hosting $0.026/GB, Artifact Registry $0.10/GB.

---

### `cleanup-cloudrun.sh` — prune old Cloud Run revisions and AR images

```bash
cleanup-cloudrun              # uses defaults from .env
DRY_RUN=1 cleanup-cloudrun   # preview without deleting
KEEP_COUNT=5 cleanup-cloudrun
```

Deletes old Cloud Run revisions and Artifact Registry Docker images, keeping the
most recent `KEEP_COUNT` (default: 3). Meant to be run periodically to prevent
image storage from accumulating.

Configure via `.env` in the same directory or environment variables:

```bash
# Required
GOOGLE_CLOUD_PROJECT=my-project
SERVICE_NAME=my-service
REPO_NAME=my-repo

# Optional
GOOGLE_CLOUD_REGION=us-central1   # default
KEEP_COUNT=3                       # default
```

---

## Setup

### Prerequisites

- `gcloud` CLI, authenticated (`gcloud auth login`)
- `python3`
- `curl`

### Install to PATH

```bash
ln -s /Users/steve/Development/gcp-tools/gcp-cost-report.sh ~/bin/gcp-cost-report
ln -s /Users/steve/Development/gcp-tools/cleanup-cloudrun.sh ~/bin/cleanup-cloudrun
```
