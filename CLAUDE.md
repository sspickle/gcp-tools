# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Two standalone bash scripts for GCP cost visibility and cleanup. No build system, no tests, no dependencies beyond `gcloud`, `python3`, and `curl`.

## Scripts

**`gcp-cost-report.sh`** — takes a single GCP project ID, detects enabled APIs (`firebasehosting`, `artifactregistry`, `run`, `appengine`, `datastore`, `compute`), and reports storage usage with estimated costs. Accepts `--billing-csv <file>` to show a ground-truth billing summary from a GCP billing report CSV alongside the per-resource analysis. Uses `python3` inline for float math (avoids `bc`/`awk` portability issues).

**`cleanup-cloudrun.sh`** — deletes old Cloud Run revisions and Artifact Registry Docker images, keeping the newest `KEEP_COUNT`. Reads config from `.env` in the script's directory or environment variables. Requires `GOOGLE_CLOUD_PROJECT` to be set.

## Running

```bash
# Cost report
./gcp-cost-report.sh <project-id>
./gcp-cost-report.sh <project-id> --billing-csv ~/Downloads/billing.csv
./gcp-cost-report.sh <project-id> --dry-run

# Cleanup (configure via .env or env vars first)
./cleanup-cloudrun.sh
DRY_RUN=1 ./cleanup-cloudrun.sh
KEEP_COUNT=5 ./cleanup-cloudrun.sh
```

## `.env` for cleanup-cloudrun.sh

```bash
# Required
GOOGLE_CLOUD_PROJECT=my-project
SERVICE_NAME=my-service
REPO_NAME=my-repo

# Optional
GOOGLE_CLOUD_REGION=us-central1   # default
KEEP_COUNT=3                       # default
```

## Design notes

- Both scripts use `set -euo pipefail` — any unhandled error exits immediately.
- API detection in `gcp-cost-report.sh` uses `has_api()` against `gcloud services list --enabled` output. Add new service checks there when extending.
- Float arithmetic uses `python3 -c "..."` one-liners (`cost()`, `addcost()` functions) rather than `bc` to avoid platform differences.
- `cleanup-cloudrun.sh` skips revisions serving traffic silently (the `gcloud` delete returns non-zero; the `|| echo "(skipped)"` absorbs it).
- Cloud Run revision counts in `gcp-cost-report.sh` are informational only — images are billed through Artifact Registry.
- Pricing constants are hardcoded: Firebase Hosting `$0.026/GB`, Artifact Registry `$0.10/GB`, App Engine GCS `$0.020/GB`, Datastore `$0.108/GB`. Update them at the top of `gcp-cost-report.sh` if rates change.
- App Engine deployment storage is read from `gs://staging.<project>.appspot.com` via the GCS JSON API (pagination handled in Python inline). Datastore storage comes from the `__Stat_Total__` internal entity via the Datastore REST API — Datastore mode only; Firestore Native mode is not supported. Both return 0 gracefully if the bucket/database doesn't exist.
- Compute Engine section queries instances (informational), all persistent disks (cost estimated by type: pd-standard $0.040, pd-balanced $0.100, pd-ssd $0.170/GB), and reserved static IPs (unused ones flagged at ~$7.20/mo). Orphaned disks (no attached instance) and unused IPs are highlighted with `←` warnings.
- `--billing-csv` accepts the CSV from GCP Billing > Reports (the format with "Service description", "Subtotal ($)", "Percent change" columns). Services not analyzed by the script are flagged with `← not analyzed`. The billing CSV section appears between the per-service sections and the summary.
- Help text is extracted dynamically using awk between the `# ===` block markers, so line numbers don't need updating when the header changes.
