# gcp-tools

CLI scripts for managing and reporting on GCP / Firebase projects.

## Scripts

### `gcp-cost-report.sh` — storage cost report

Reports storage usage and estimated monthly costs for any GCP or Firebase project.
Auto-detects project type by checking which APIs are enabled.

**Covers:**
- Firebase Hosting — all sites, all release versions
- Artifact Registry — Docker image sizes per repo
- Cloud Run — service/revision inventory (images billed via AR)

```bash
./gcp-cost-report.sh <project-id>
./gcp-cost-report.sh <project-id> --dry-run
```

Example output:
```
━━━ GCP Storage Cost Report: my-project ━━━

  Detecting enabled APIs... Firebase, Cloud Run/AR

  ▸ Firebase Hosting  ($0.026/GB/mo)
    my-project                            21 releases    12.52 MB  ~$0.00032/mo

  ▸ Artifact Registry  ($0.10/GB/mo)
    my-app (us-central1)                  15 images       2.30 GB  ~$0.23000/mo

  ▸ Cloud Run  (informational)
    my-app           us-central1           3 revisions

━━━ Summary: my-project ━━━
  Firebase Hosting:             12.52 MB  ~$0.00032/mo
  Artifact Registry:             2.30 GB  ~$0.23000/mo
  ──────────────────────────────────────────────────
  Total:                         2.31 GB  ~$0.23032/mo
```

**Pricing used:** Firebase Hosting $0.026/GB, Artifact Registry $0.10/GB.
Excludes free tiers and egress charges.

---

### `cleanup-cloudrun.sh` — delete old Cloud Run revisions and AR images

Deletes old Cloud Run revisions and Artifact Registry images, keeping the most
recent `KEEP_COUNT` of each.

```bash
./cleanup-cloudrun.sh                  # uses defaults
DRY_RUN=1 ./cleanup-cloudrun.sh       # preview without deleting
KEEP_COUNT=5 ./cleanup-cloudrun.sh    # keep 5 instead of 3
```

**Environment / `.env`:**
```
GOOGLE_CLOUD_PROJECT=my-project
GOOGLE_CLOUD_REGION=us-central1   # default
SERVICE_NAME=my-service           # default: trinket
REPO_NAME=my-repo                 # default: trinket
KEEP_COUNT=3                      # default
```

---

## Prerequisites

- `gcloud` CLI, authenticated (`gcloud auth login`)
- `python3` (used for JSON parsing and float arithmetic)
- `curl`
