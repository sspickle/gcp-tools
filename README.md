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

### `cleanup-scan.py` — fleet triage: which projects need a cleanup

```bash
uv run cleanup-scan.py            # scan every project across all gcloud configs
./cleanup-scan.py PROJECT …       # scan only the named projects
./cleanup-scan.py --all           # also list projects that are already clean
./cleanup-scan.py --keep 5 --workers 12
```

Read-only. It never deletes anything — it just answers "which projects would
repay a `cleanup-cloudrun` run?" so you can spend cleanup effort where it counts.

For every project reachable from your gcloud configs (discovery spans both
accounts) it counts what is deletable beyond the keep-count in each category
`cleanup-cloudrun` handles — Cloud Run revisions, App Engine versions (a version
serving traffic is never counted), Artifact Registry image versions and repo
footprint, Secret Manager versions — plus build-scratch buckets missing a
lifecycle rule (sized with `du -s`, since one un-swept `_cloudbuild` bucket can
hold more than every image in the project) and a non-empty legacy
`us.artifacts.<project>.appspot.com` bucket (which points you at
`gcr-prune-orphans.py`). Projects with anything to reclaim print first, ranked
by total reclaimable storage — AR footprint plus build-scratch bytes — each
with the exact command to run:

```
━━━ Projects ready for cleanup ━━━

  trinket-merge-test   33 excess AR images, 28.0GB AR footprint, 40 excess Cloud Run revisions
  instructormi4edtest  1 build bucket(s) w/o lifecycle (25.2GB)
  trinket-uindy        5 excess AR images, 6.0GB AR footprint, 5 excess Cloud Run revisions
  glowscript-py38      1.6GB AR footprint, legacy GCR bucket (→ gcr-prune-orphans)

  Run (dry-run first):
    CLOUDSDK_ACTIVE_CONFIG_NAME=assets cleanup-cloudrun trinket-merge-test --dry-run
    …
```

Scans run in a thread pool (default 8 projects at once); a full ~26-project
fleet takes about 30 seconds. A single-file [PEP 723](https://peps.python.org/pep-0723/)
uv script — stdlib-only, no dependencies.

---

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

### `gcr-prune-orphans.py` — reclaim orphaned GCR layer blobs

```bash
uv run gcr-prune-orphans.py <project-id>            # dry run (the default)
./gcr-prune-orphans.py <project-id>                 # same — the shebang runs it under uv
uv run gcr-prune-orphans.py <project-id> --delete   # actually delete
```

Deleting a GCR image removes its manifest and tags but leaves the layer blobs
in the legacy `us.artifacts.<project>.appspot.com` bucket, and GCR's own garbage
collection is unreliable — so `cleanup-cloudrun` trims images without the storage
dropping. This finds bucket blobs that no surviving manifest references and (with
`--delete`) removes them.

The keep-set is built from **every** manifest still in the `us.gcr.io/<project>`
tree (recursively) plus active Cloud Run revision images, so it never deletes a
blob a live image needs. Safety: it **refuses to delete** on an incomplete
keep-set (a failed registry enumeration or manifest read) or a failed integrity
check — every image resident in the bucket must still have all its layers — and
requires you to type the project id before a total wipe. Dry run is the default;
`--dry-run` forces it and wins if combined with `--delete`.

Post GCR→Artifact-Registry migration a project's live images keep their blobs in
AR rather than this legacy bucket; those are correctly excluded, so what remains
to prune is genuinely orphaned build scratch.

A single-file [PEP 723](https://peps.python.org/pep-0723/) uv script —
stdlib-only, no dependencies. Runs under `uv` (pinned interpreter) or plain
`python3 gcr-prune-orphans.py …`.

---

## Setup

### Prerequisites

- `gcloud` CLI, authenticated (`gcloud auth login`)
- `python3` (used inline by the bash scripts)
- `uv` (runs `gcr-prune-orphans.py`; plain `python3 gcr-prune-orphans.py` also works)
- `curl`

### Install to PATH

```bash
ln -s /Users/steve/Development/gcp-tools/gcp-cost-report.sh ~/bin/gcp-cost-report
ln -s /Users/steve/Development/gcp-tools/cleanup-cloudrun.sh ~/bin/cleanup-cloudrun
ln -s /Users/steve/Development/gcp-tools/gcp-bucket-summary.sh ~/bin/gcp-bucket-summary
ln -s /Users/steve/Development/gcp-tools/gcr-prune-orphans.py ~/bin/gcr-prune-orphans
ln -s /Users/steve/Development/gcp-tools/cleanup-scan.py ~/bin/cleanup-scan
```
