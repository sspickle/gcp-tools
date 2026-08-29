# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Standalone CLI tools for GCP cost visibility and cleanup: bash scripts (`gcp-cost-report.sh`, `cleanup-cloudrun.sh`, `gcp-bucket-summary.sh`) plus two uv single-file Python scripts (`gcr-prune-orphans.py`, `cleanup-scan.py`). No build system, no tests. Dependencies: `gcloud`, `python3`, `curl`, and `uv` (for the Python scripts; they also run under plain `python3`).

## Scripts

**`gcp-cost-report.sh`** — takes a single GCP project ID, detects enabled APIs (`firebasehosting`, `artifactregistry`, `run`, `appengine`, `datastore`, `compute`), and reports storage usage with estimated costs. Accepts `--billing-csv <file>` to show a ground-truth billing summary from a GCP billing report CSV alongside the per-resource analysis. Uses `python3` inline for float math (avoids `bc`/`awk` portability issues).

**`cleanup-cloudrun.sh`** — deletes old Cloud Run revisions and Artifact Registry Docker images, keeping the newest `KEEP_COUNT`. Three modes: auto-discover (default, no `SERVICE_NAME`), targeted (`SERVICE_NAME` set), and `--sweep-repo` (legacy GCR). Reads config from `.env` in the script's directory or environment variables.

**`cleanup-scan.py`** — read-only fleet triage that answers "which projects would repay a `cleanup-cloudrun` run?" A [PEP 723](https://peps.python.org/pep-0723/) uv single-file script (stdlib-only), like `gcr-prune-orphans.py`. Discovers projects once per distinct account across all gcloud configs (visibility follows the account, not the config), then scans each project (thread pool, default 8 workers) counting what is deletable beyond the keep-count in every category `cleanup-cloudrun` handles — Cloud Run revisions, App Engine versions (never a version serving traffic), Artifact Registry image versions + repo footprint, Secret Manager active versions — plus build-scratch buckets missing a lifecycle rule and a *non-empty* legacy `us.artifacts.<project>.appspot.com` bucket. Never deletes; prints ready projects first (ranked by AR footprint, then legacy-GCR presence, then excess-item count), each with the exact `CLOUDSDK_ACTIVE_CONFIG_NAME=<cfg> cleanup-cloudrun <project> --dry-run` command. Every gcloud call uses `stdin=DEVNULL` so a disabled-API prompt can't hang the scan, and a failing call is treated as "nothing here" so one unreachable project never sinks the run. Storage-bucket checks run unconditionally (Cloud Storage is often absent from the enabled-APIs list even where buckets exist); the legacy-bucket check is a single non-recursive listing so a freshly-pruned but still-present bucket isn't re-flagged.

**`gcr-prune-orphans.py`** — reclaims the layer blobs that `cleanup-cloudrun`'s manifest deletion leaves orphaned in the legacy `us.artifacts.<project>.appspot.com` GCS bucket (GCR doesn't GC them reliably). A [PEP 723](https://peps.python.org/pep-0723/) uv single-file script: `#!/usr/bin/env -S uv run --script`, stdlib-only (no dependencies), so `./gcr-prune-orphans.py` runs under uv with a pinned interpreter — plain `python3` also works. Dry run by default; `--delete` to act; `--dry-run` forces dry run and wins over `--delete`. Builds the keep-set from the whole `us.gcr.io/<project>` manifest tree (via GCR's `/v2/<repo>/tags/list`, which returns full digests — `gcloud list-tags --format=value(digest)` truncates) plus Cloud Run revisions, and refuses to `--delete` on an incomplete keep-set or a failed per-image integrity check. Bucket blobs of images migrated to the Artifact Registry backend are correctly excluded (they live in AR, not this bucket).

## Running

```bash
# Fleet cleanup triage — which projects are worth a cleanup run (read-only)
uv run cleanup-scan.py                 # all projects across all configs
./cleanup-scan.py <project-id> …       # only the named projects
./cleanup-scan.py --all                # also list already-clean projects

# Cost report
./gcp-cost-report.sh <project-id>
./gcp-cost-report.sh <project-id> --billing-csv ~/Downloads/billing.csv
./gcp-cost-report.sh <project-id> --dry-run

# Cleanup — auto-discover all services in a project
./cleanup-cloudrun.sh my-project
DRY_RUN=1 ./cleanup-cloudrun.sh my-project
KEEP_COUNT=5 ./cleanup-cloudrun.sh my-project

# Cleanup — targeted (SERVICE_NAME set in .env)
./cleanup-cloudrun.sh

# Cleanup — legacy GCR sweep
REPOSITORY=us.gcr.io/my-project ./cleanup-cloudrun.sh --sweep-repo

# Orphaned-blob prune (dry run by default; --delete to act)
uv run gcr-prune-orphans.py my-project
./gcr-prune-orphans.py my-project --delete
```

## `.env` for cleanup-cloudrun.sh

```bash
# Required for targeted mode; auto-discover only needs GOOGLE_CLOUD_PROJECT
GOOGLE_CLOUD_PROJECT=my-project
SERVICE_NAME=my-service   # omit to auto-discover all services
REPO_NAME=my-repo         # required when SERVICE_NAME is set

# Optional
GOOGLE_CLOUD_REGION=us-central1   # default (targeted mode only)
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
