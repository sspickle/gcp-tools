#!/bin/bash
set -euo pipefail

# =============================================================================
# Clean up old Cloud Run revisions and Artifact Registry images (keeping the
# most recent KEEP_COUNT of each), and set an auto-expiry lifecycle rule on
# build-scratch storage buckets.
#
# Usage:
#   cleanup-cloudrun [PROJECT_ID] [--dry-run]          # auto-discover all
#   cleanup-cloudrun [PROJECT_ID] [--dry-run]          # targeted if SERVICE_NAME set
#   cleanup-cloudrun --sweep-repo                      # legacy GCR
#
# Auto-discover mode (default when SERVICE_NAME is not set):
#   Finds all Cloud Run services, App Engine versions, AR repos, and Secret
#   Manager secrets in the project and trims each. App Engine versions serving
#   traffic are never deleted.
#   Required: GOOGLE_CLOUD_PROJECT (or pass as first argument)
#   Optional: KEEP_COUNT (default: 3), SECRET_KEEP_COUNT (default: 1),
#             BUCKET_AGE_DAYS (default: 30)
#
# Targeted mode (when SERVICE_NAME is set in .env or environment):
#   Trims a specific Cloud Run service, its AR image, and known secrets.
#   Required: GOOGLE_CLOUD_PROJECT, SERVICE_NAME, REPO_NAME
#   Optional: KEEP_COUNT (default: 3), GOOGLE_CLOUD_REGION (default: us-central1),
#             IMAGE_NAME (default: SERVICE_NAME), SECRET_KEEP_COUNT (default: 1),
#             SECRETS (space-separated list of secret names to trim)
#
# --sweep-repo mode (legacy Container Registry):
#   Sweeps every image in a GCR repo RECURSIVELY (nested paths included, e.g.
#   app-engine-tmp/app/default/ttl-18h), keeping the newest KEEP_COUNT versions.
#   Required: REPOSITORY (e.g. us.gcr.io/my-project)
#   Optional: KEEP_COUNT (default: 1), GCR_MAX_DEPTH (default: 8)
#
# Common:
#   DRY_RUN=1   Print what would be deleted without deleting
# =============================================================================

# --- help (works at any argument position) ---
for _arg in "$@"; do
  if [[ "$_arg" == "-h" || "$_arg" == "--help" ]]; then
    cat <<'EOF'
Usage: cleanup-cloudrun [PROJECT_ID] [--dry-run]
       cleanup-cloudrun --sweep-repo

Auto-discover mode (default when SERVICE_NAME is not set):
  Finds all Cloud Run services, App Engine versions, AR repos, Secret Manager
  secrets, and build-scratch buckets and trims each. App Engine versions serving
  traffic are never deleted; build buckets get a delete-after-N-days rule.
  Required: GOOGLE_CLOUD_PROJECT (or pass as first argument)
  Optional: KEEP_COUNT (default: 3), SECRET_KEEP_COUNT (default: 1),
            BUCKET_AGE_DAYS (default: 30), DRY_RUN=1

Targeted mode (when SERVICE_NAME is set in .env or environment):
  Trims a specific Cloud Run service, its AR image, and named secrets.
  Required: GOOGLE_CLOUD_PROJECT, SERVICE_NAME, REPO_NAME
  Optional: KEEP_COUNT (default: 3), GOOGLE_CLOUD_REGION (default: us-central1),
            IMAGE_NAME (default: SERVICE_NAME), SECRET_KEEP_COUNT (default: 1),
            SECRETS (space-separated list of secret names to trim)

--sweep-repo mode (legacy Container Registry):
  Sweeps every image in a GCR repository RECURSIVELY, keeping the newest
  KEEP_COUNT versions. Nested paths count: App Engine hides its build scratch
  several levels down (app-engine-tmp/app/default/ttl-18h) and that is usually
  the bulk of the repo.
  Required: REPOSITORY (e.g. us.gcr.io/my-project)
  Optional: KEEP_COUNT (default: 1), GCR_MAX_DEPTH (default: 8)

Common:
  DRY_RUN=1   Print what would be deleted without deleting
EOF
    exit 0
  fi
done

# --- load .env ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  source "${SCRIPT_DIR}/.env"
fi

# --- parse args ---
PROJECT_ARG=""
DRY_RUN="${DRY_RUN:-0}"
SWEEP_REPO=0
# Recursion limit for the legacy GCR tree. Real nesting tops out around 4
# (app-engine-tmp/app/default/ttl-18h); this is a runaway guard, not a tuning knob.
GCR_MAX_DEPTH="${GCR_MAX_DEPTH:-8}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sweep-repo) SWEEP_REPO=1 ;;
    --dry-run)    DRY_RUN=1 ;;
    -*)           echo "Unknown option: $1" >&2; exit 1 ;;
    *)
      if [[ -z "${PROJECT_ARG}" ]]; then
        PROJECT_ARG="$1"
      else
        echo "Unexpected argument: $1" >&2; exit 1
      fi
      ;;
  esac
  shift
done

# Final banner. A run that could not read part of the project is not a clean
# run: say so, and exit non-zero so a caller can tell.
finish() {
  if [[ -s "${_DEGRADED_FLAG}" ]]; then
    echo "=== Done (DEGRADED -- some gcloud calls failed; see !! above) ==="
    exit 2
  fi
  echo "=== Done ==="
}

# ---------------------------------------------------------------------------
# gcloud plumbing.
#
# Every read below used to end in `2>/dev/null || true`, which collapses any
# failure -- expired token, wrong account, disabled API, missing permission --
# into an empty string. Empty then reads as "the resource does not exist", so
# the script reports "no services found" for a project full of services.
#
# That is the worst failure mode a cleanup tool can have: it is indistinguish-
# able from a clean project, and it hides precisely the misconfiguration you
# need to see. Worse, it is silently self-consistent -- every section agrees
# the project is empty, so nothing looks wrong.
#
# So: capture stderr, keep the exit status, and let callers tell "failed" and
# "empty" apart. A failed read is reported and marks the run degraded; it never
# masquerades as an empty result.
# ---------------------------------------------------------------------------
# The flag lives in a file, not a variable: gcloud_query is almost always
# called as $(gcloud_query ...), which runs it in a subshell, and a variable
# set there dies with the subshell. A file outlives it.
_DEGRADED_FLAG="$(mktemp)"
trap 'rm -f "${_DEGRADED_FLAG}"' EXIT

_mark_degraded() { echo 1 >> "${_DEGRADED_FLAG}"; }

# Read-only gcloud query. Echoes stdout on success. On failure, explains itself
# on stderr, flags the run, and returns non-zero -- distinct from "returned
# nothing", which is a legitimate answer this must never fake.
gcloud_query() {
  local label="$1"; shift
  local err out rc=0
  err="$(mktemp)"
  out="$(gcloud "$@" 2>"${err}")" || rc=$?
  if [[ ${rc} -ne 0 ]]; then
    _mark_degraded
    echo "  !! ${label}: gcloud exited ${rc} -- this section is NOT a clean result" >&2
    head -5 "${err}" | sed 's/^/     /' >&2
    rm -f "${err}"
    return 1
  fi
  rm -f "${err}"
  printf '%s' "${out}"
}

# Mutating gcloud command. Reports the actual reason on failure instead of a
# bare "(skipped)", which told you something did not happen but never why.
gcloud_mutate() {
  local indent="$1"; shift
  local err rc=0
  err="$(mktemp)"
  gcloud "$@" >/dev/null 2>"${err}" || rc=$?
  if [[ ${rc} -ne 0 ]]; then
    _mark_degraded
    echo "${indent}(FAILED) $(head -2 "${err}" | tr '\n' ' ' | tr -s ' ')"
    rm -f "${err}"
    return 1
  fi
  rm -f "${err}"
}

# ---------------------------------------------------------------------------
# Helper: keep the newest `keep` manifests of ONE legacy GCR image path.
# Silent when the path holds no manifests of its own: in GCR a path is both a
# possible image and a parent of other images, and most parents are empty.
# ---------------------------------------------------------------------------
trim_gcr_image() {
  local image_url="$1" keep="$2"

  local digests
  digests=$(gcloud_query "list-tags ${image_url}" container images list-tags "${image_url}" \
    --sort-by="~timestamp" \
    --format="value(digest)") || return 0

  [[ -z "${digests}" ]] && return 0

  echo "  ${image_url}"
  local count=0
  while IFS= read -r digest; do
    [[ -z "${digest}" ]] && continue
    count=$((count + 1))
    [[ "${digest}" != sha256:* ]] && digest="sha256:${digest}"
    if [[ ${count} -le ${keep} ]]; then
      echo "    keeping  ${digest:0:19}..."
    else
      echo "    deleting ${digest:0:19}..."
      if [[ "${DRY_RUN}" != "1" ]]; then
        gcloud_mutate "      " container images delete "${image_url}@${digest}" \
          --force-delete-tags \
          --quiet || true
      fi
    fi
  done <<< "${digests}"
}

# ---------------------------------------------------------------------------
# Helper: sweep a legacy GCR repository RECURSIVELY.
#
# `gcloud container images list --repository=X` returns only the immediate
# children of X, never a full tree, and GCR nests arbitrarily deep. App Engine
# writes its build scratch several levels down, e.g.
#     us.gcr.io/PROJECT/app-engine-tmp/app/default/ttl-18h
# A single-level sweep sees `app-engine-tmp`, finds no manifests directly on
# it, prints "no versions found", and moves on -- silently missing everything
# underneath. On an App Engine project that is most of the repository: on
# glowscript-py38 it hid 90 of 98 manifests (~10GB, the fleet's largest single
# line item) for as long as this script has existed.
#
# The `ttl-18h`/`ttl-7d` names are Google's own expiry hint, but nothing
# enforces them -- they pile up one batch per `gcloud app deploy` until swept.
# ---------------------------------------------------------------------------
sweep_gcr_repo() {
  local repository="$1" keep="$2" depth="${3:-0}"

  if [[ ${depth} -ge ${GCR_MAX_DEPTH} ]]; then
    echo "  (max depth ${GCR_MAX_DEPTH} reached at ${repository} — not descending)"
    return 0
  fi

  # A node can hold manifests AND children: trim here, then descend.
  trim_gcr_image "${repository}" "${keep}"

  local children
  children=$(gcloud_query "list children of ${repository}" container images list \
    --repository="${repository}" \
    --format="value(name)") || return 0

  [[ -z "${children}" ]] && return 0

  while IFS= read -r child; do
    [[ -z "${child}" ]] && continue
    sweep_gcr_repo "${child}" "${keep}" $((depth + 1))
  done <<< "${children}"
}

# ---------------------------------------------------------------------------
# --sweep-repo mode: keep newest KEEP_COUNT versions of every image in a
# legacy Container Registry repository (uses gcloud container images, not AR)
# ---------------------------------------------------------------------------
if [[ $SWEEP_REPO -eq 1 ]]; then
  REPOSITORY="${REPOSITORY:?Set REPOSITORY (e.g. us.gcr.io/PROJECT) in .env or environment}"
  KEEP_COUNT="${KEEP_COUNT:-1}"

  [[ "${DRY_RUN}" == "1" ]] && echo "--- DRY RUN — nothing will be deleted ---"
  echo "Repository: ${REPOSITORY}"
  echo "Keeping newest ${KEEP_COUNT} version(s) of each image"
  echo ""

  sweep_gcr_repo "${REPOSITORY}" "${KEEP_COUNT}"

  echo ""
  finish
  exit 0
fi

# --- resolve project and common config ---
GOOGLE_CLOUD_PROJECT="${PROJECT_ARG:-${GOOGLE_CLOUD_PROJECT:-}}"
GOOGLE_CLOUD_PROJECT="${GOOGLE_CLOUD_PROJECT:?Set GOOGLE_CLOUD_PROJECT in .env, the environment, or pass as first argument}"
KEEP_COUNT="${KEEP_COUNT:-3}"
SECRET_KEEP_COUNT="${SECRET_KEEP_COUNT:-1}"

_ACTIVE_ACCOUNT=$(gcloud config get-value account 2>/dev/null || true)
_ACTIVE_CONFIG=$(gcloud config configurations list --filter="is_active=true" --format="value(name)" 2>/dev/null || true)

[[ "${DRY_RUN}" == "1" ]] && echo "--- DRY RUN — nothing will be deleted ---"
echo "Project:  ${GOOGLE_CLOUD_PROJECT}"
echo "Account:  ${_ACTIVE_ACCOUNT:-unknown} (config: ${_ACTIVE_CONFIG:-default})"
echo "Keeping last ${KEEP_COUNT} revisions/images per service"
echo ""

# Verify this identity can actually read this project, before anything else.
# Without this the run continues under a stale or wrong account and reports
# every section as empty -- the failure gcloud_query exists to prevent, caught
# once here instead of section by section.
if ! gcloud_query "project access" projects describe "${GOOGLE_CLOUD_PROJECT}" \
     --format="value(projectId)" >/dev/null; then
  echo "" >&2
  echo "Cannot read project ${GOOGLE_CLOUD_PROJECT} as ${_ACTIVE_ACCOUNT:-unknown}." >&2
  echo "Check the active config (gcloud config configurations list), or" >&2
  echo "re-authenticate: gcloud auth login ${_ACTIVE_ACCOUNT:-}" >&2
  exit 1
fi

# Confirm account+project before destructive operations.
# Set GCLOUD_ACCOUNT_OK=1 to skip (e.g. in CI or when piping output).
if [[ -z "${GCLOUD_ACCOUNT_OK:-}" ]]; then
  read -r -p "Proceed with this account and project? [y/N] " _CONFIRM
  if [[ "${_CONFIRM}" != "y" && "${_CONFIRM}" != "Y" ]]; then
    echo "Aborted."
    exit 1
  fi
  echo ""
fi

# ---------------------------------------------------------------------------
# Helper: trim old App Engine versions, keeping the newest `keep` per service.
#
# App Engine retains every version ever deployed, and each one holds its own
# code and build artifacts -- the same accumulation Cloud Run revisions have,
# on a service this script otherwise ignores entirely. `--no-promote` deploys
# make it worse: they add a version that will never take traffic on its own.
#
# A version serving ANY traffic is never deleted, regardless of age: a traffic
# split can leave an old version live (canary/rollback), so age alone is not a
# safe signal. Deleting a version is irreversible -- the newest `keep` are held
# back as rollback targets.
# ---------------------------------------------------------------------------
trim_app_versions() {
  local keep="$1"

  # No App Engine app here? Nothing to do -- most projects have none.
  if ! gcloud app describe --project="${GOOGLE_CLOUD_PROJECT}" >/dev/null 2>&1; then
    echo "  no App Engine app in this project"
    return 0
  fi

  local versions
  if ! versions=$(gcloud_query "App Engine versions" app versions list \
    --project="${GOOGLE_CLOUD_PROJECT}" \
    --sort-by="service,~version.createTime" \
    --format="value(service,id,traffic_split)"); then
    echo "  !! cannot list versions -- skipping App Engine (nothing deleted)"
    return 0
  fi

  if [[ -z "${versions}" ]]; then
    echo "  no versions found"
    return 0
  fi

  # Grouped by service via the sort above, so a prev/counter pair is enough --
  # bash 3.2 (macOS default) has no associative arrays.
  local prev_svc="" count=0
  while IFS=$'\t' read -r svc id split; do
    [[ -z "${svc}" || -z "${id}" ]] && continue

    if [[ "${svc}" != "${prev_svc}" ]]; then
      echo "  service: ${svc}"
      prev_svc="${svc}"
      count=0
    fi
    count=$((count + 1))

    # traffic_split is a float ("1.00", "0.50"); awk keeps this shell-portable.
    if awk "BEGIN{exit !(${split:-0} > 0)}"; then
      echo "    keeping  ${id}  (serving ${split})"
      continue
    fi

    if [[ ${count} -le ${keep} ]]; then
      echo "    keeping  ${id}"
    else
      echo "    deleting ${id}"
      if [[ "${DRY_RUN}" != "1" ]]; then
        gcloud_mutate "      " app versions delete "${id}" \
          --service="${svc}" \
          --project="${GOOGLE_CLOUD_PROJECT}" \
          --quiet || true
      fi
    fi
  done <<< "${versions}"
}

# ---------------------------------------------------------------------------
# Helper: trim old revisions for one Cloud Run service
# ---------------------------------------------------------------------------
trim_revisions() {
  local svc="$1" region="$2"
  echo "  revisions: ${svc} (${region})"

  local revisions
  if ! revisions=$(gcloud_query "revisions of ${svc}" run revisions list \
    --service="${svc}" \
    --region="${region}" \
    --project="${GOOGLE_CLOUD_PROJECT}" \
    --sort-by="~metadata.creationTimestamp" \
    --format="value(metadata.name)"); then
    echo "    !! cannot list revisions -- skipping ${svc} (nothing deleted)"
    return
  fi

  if [[ -z "${revisions}" ]]; then
    echo "    no revisions found"
    return
  fi

  local count=0
  while IFS= read -r rev; do
    count=$((count + 1))
    if [[ ${count} -le ${KEEP_COUNT} ]]; then
      echo "    keeping  ${rev}"
    else
      echo "    deleting ${rev}"
      if [[ "${DRY_RUN}" != "1" ]]; then
        gcloud_mutate "      " run revisions delete "${rev}" \
          --region="${region}" \
          --project="${GOOGLE_CLOUD_PROJECT}" \
          --quiet || true
      fi
    fi
  done <<< "${revisions}"
}

# ---------------------------------------------------------------------------
# Helper: trim old versions of one AR image path
# ---------------------------------------------------------------------------
trim_ar_image() {
  local img_path="$1" label="$2"
  echo "  images:    ${label}"

  local digests
  local raw
  if ! raw=$(gcloud_query "images in ${img_path}" artifacts docker images list "${img_path}" \
    --format="value(createTime,version)" \
    --project="${GOOGLE_CLOUD_PROJECT}"); then
    echo "    !! cannot list images -- skipping ${label} (nothing deleted)"
    return
  fi
  digests=$(printf '%s\n' "${raw}" | grep -v "^Listing" | sort -r | awk '{print $2}')

  if [[ -z "${digests}" ]]; then
    echo "    no versions found"
    return
  fi

  local count=0
  while IFS= read -r digest; do
    [[ -z "${digest}" ]] && continue
    count=$((count + 1))
    if [[ ${count} -le ${KEEP_COUNT} ]]; then
      echo "    keeping  ${digest:0:19}..."
    else
      echo "    deleting ${digest:0:19}..."
      if [[ "${DRY_RUN}" != "1" ]]; then
        gcloud_mutate "      " artifacts docker images delete \
          "${img_path}@${digest}" \
          --delete-tags \
          --async \
          --project="${GOOGLE_CLOUD_PROJECT}" \
          --quiet || true
      fi
    fi
  done <<< "${digests}"
}

# ---------------------------------------------------------------------------
# Helper: destroy old active versions of a Secret Manager secret, keeping
# the newest KEEP (default 1). Storage bills per ACTIVE version-replica, where
# active = ENABLED *or* DISABLED — only DESTROYED versions stop billing (and
# the 6-version free tier counts enabled+disabled alike). So we must destroy,
# not merely disable, to actually reclaim storage cost.
# ---------------------------------------------------------------------------
trim_secret_versions() {
  local secret="$1" keep="${2:-1}"
  echo "  secret: ${secret}"

  # All active (enabled or disabled) versions, newest first. Both states bill.
  local versions
  if ! versions=$(gcloud_query "versions of ${secret}" secrets versions list "${secret}" \
    --project="${GOOGLE_CLOUD_PROJECT}" \
    --filter="state=ENABLED OR state=DISABLED" \
    --sort-by="~createTime" \
    --format="value(name)"); then
    echo "    !! cannot list versions -- skipping ${secret} (nothing destroyed)"
    return
  fi

  if [[ -z "${versions}" ]]; then
    echo "    no active versions found"
    return
  fi

  local count=0
  while IFS= read -r ver; do
    [[ -z "${ver}" ]] && continue
    count=$((count + 1))
    if [[ ${count} -le ${keep} ]]; then
      echo "    keeping  ${ver}"
    else
      echo "    destroying ${ver}"
      if [[ "${DRY_RUN}" != "1" ]]; then
        gcloud_mutate "      " secrets versions destroy "${ver}" \
          --secret="${secret}" \
          --project="${GOOGLE_CLOUD_PROJECT}" \
          --quiet || true
      fi
    fi
  done <<< "${versions}"
}

# ---------------------------------------------------------------------------
# Helper: give build-scratch buckets an auto-expiry lifecycle rule.
#
# Cloud Build drops a source tarball in gs://<project>_cloudbuild on EVERY build,
# and App Engine stages each deploy in gs://staging.<project>.appspot.com; both
# accumulate one object per deploy forever with no default expiry (this is the
# Cloud Storage line item that grows quietly). Unlike images/revisions we don't
# delete anything here -- we set a delete-after-N-days lifecycle rule so GCS
# expires old objects itself. Idempotent: a bucket that already has ANY rule is
# left alone.
#
# We match ONLY build-scratch buckets and deliberately skip everything else:
#   - *.artifacts.*.appspot.com / *.gcr.io -> container image layers (handled by
#     the AR / GCR sweeps; a delete rule here would drop image data)
#   - app-data buckets (trinket-materials, -snapshots, -user-assets, etc.) ->
#     NEVER touched; expiring user data would be catastrophic
# ---------------------------------------------------------------------------
trim_build_buckets() {
  local age="${BUCKET_AGE_DAYS:-30}"

  local buckets
  if ! buckets=$(gcloud_query "storage buckets" storage buckets list \
    --project="${GOOGLE_CLOUD_PROJECT}" \
    --format="value(name)"); then
    echo "  !! cannot list buckets -- skipping storage (no rules set)"
    return 0
  fi

  if [[ -z "${buckets}" ]]; then
    echo "  no buckets found"
    return 0
  fi

  local found=0
  while IFS= read -r bucket; do
    [[ -z "${bucket}" ]] && continue
    # Allowlist build-scratch names only. `staging.*.appspot.com` is App Engine
    # deploy scratch; `*_cloudbuild` is Cloud Build source. Anything else -- app
    # data, image-backing artifacts buckets -- is skipped.
    case "${bucket}" in
      *_cloudbuild|staging.*.appspot.com|gcf-sources-*) ;;
      *) continue ;;
    esac
    found=1

    # Already has a lifecycle rule? Leave it be (idempotent across runs).
    local existing
    if ! existing=$(gcloud_query "describe gs://${bucket}" storage buckets describe "gs://${bucket}" \
      --project="${GOOGLE_CLOUD_PROJECT}" \
      --format="value(lifecycle_config.rule)"); then
      echo "  skipping  gs://${bucket}  (cannot read its lifecycle config)"
      continue
    fi
    if [[ -n "${existing}" ]]; then
      echo "  keeping   gs://${bucket}  (lifecycle rule already set)"
      continue
    fi

    echo "  setting   gs://${bucket}  (delete objects older than ${age}d)"
    if [[ "${DRY_RUN}" != "1" ]]; then
      local lc
      lc="$(mktemp)"
      printf '{"rule":[{"action":{"type":"Delete"},"condition":{"age":%d}}]}' "${age}" > "${lc}"
      gcloud_mutate "      " storage buckets update "gs://${bucket}" \
        --lifecycle-file="${lc}" \
        --project="${GOOGLE_CLOUD_PROJECT}" \
        --quiet || true
      rm -f "${lc}"
    fi
  done <<< "${buckets}"

  [[ ${found} -eq 0 ]] && echo "  no build-scratch buckets found"
  return 0
}

# ---------------------------------------------------------------------------
# Targeted mode: SERVICE_NAME set in .env or environment
# ---------------------------------------------------------------------------
if [[ -n "${SERVICE_NAME:-}" ]]; then
  REPO_NAME="${REPO_NAME:?Set REPO_NAME in .env or environment for targeted mode}"
  GOOGLE_CLOUD_REGION="${GOOGLE_CLOUD_REGION:-us-central1}"
  IMAGE_NAME="${IMAGE_NAME:-${SERVICE_NAME}}"
  IMAGE_PATH="${GOOGLE_CLOUD_REGION}-docker.pkg.dev/${GOOGLE_CLOUD_PROJECT}/${REPO_NAME}/${IMAGE_NAME}"

  echo "Mode:    targeted  (${SERVICE_NAME})"
  echo ""
  trim_revisions "${SERVICE_NAME}" "${GOOGLE_CLOUD_REGION}"
  echo ""
  trim_ar_image "${IMAGE_PATH}" "${REPO_NAME}/${IMAGE_NAME}"

  if [[ -n "${SECRETS:-}" ]]; then
    echo ""
    echo "=== Secret Manager ==="
    for secret_name in ${SECRETS}; do
      trim_secret_versions "${secret_name}" "${SECRET_KEEP_COUNT}"
    done
  fi

  echo ""
  echo "=== Cloud Storage ==="
  trim_build_buckets

  echo ""
  finish
  exit 0
fi

# ---------------------------------------------------------------------------
# Auto-discover mode: enumerate all Cloud Run services and AR images
# ---------------------------------------------------------------------------
echo "Mode: auto-discover"
echo ""

# --- Cloud Run ---
echo "=== Cloud Run ==="

if ! SERVICES=$(gcloud_query "Cloud Run services" run services list \
  --project="${GOOGLE_CLOUD_PROJECT}" \
  --format="csv[no-heading](metadata.name,metadata.labels.'cloud.googleapis.com/location')"); then
  echo "  !! cannot list services -- skipping Cloud Run (nothing deleted)"
elif [[ -z "${SERVICES}" ]]; then
  echo "  no services found"
else
  while IFS=, read -r svc svc_region; do
    [[ -z "${svc}" ]] && continue
    trim_revisions "${svc}" "${svc_region}"
  done <<< "${SERVICES}"
fi

echo ""

# --- App Engine ---
echo "=== App Engine ==="
trim_app_versions "${KEEP_COUNT}"

echo ""

# --- Artifact Registry ---
echo "=== Artifact Registry ==="

if ! REPOS_JSON=$(gcloud_query "Artifact Registry repositories" artifacts repositories list \
  --project="${GOOGLE_CLOUD_PROJECT}" \
  --format="json"); then
  REPOS_JSON=""
  AR_UNREADABLE=1
fi

REPOS=$(printf '%s' "${REPOS_JSON:-[]}" | python3 -c "
import json, sys
for r in json.load(sys.stdin):
    parts = r.get('name','').split('/')
    # resource path: projects/P/locations/L/repositories/R
    if len(parts) < 6:
        continue
    location, repo_id = parts[3], parts[5]
    # skip legacy GCR bridge repos (gcr.io, us.gcr.io, etc.)
    if repo_id.endswith('.gcr.io') or repo_id == 'gcr.io':
        continue
    print(location + ',' + repo_id)
" || true)

if [[ -n "${AR_UNREADABLE:-}" ]]; then
  echo "  !! cannot list repositories -- skipping Artifact Registry (nothing deleted)"
elif [[ -z "${REPOS}" ]]; then
  echo "  no repositories found"
else
  while IFS=, read -r repo_location repo_id; do
    [[ -z "${repo_id}" ]] && continue
    image_base="${repo_location}-docker.pkg.dev/${GOOGLE_CLOUD_PROJECT}/${repo_id}"

    if ! images_json=$(gcloud_query "images in ${repo_id}" artifacts docker images list "${image_base}" \
      --project="${GOOGLE_CLOUD_PROJECT}" \
      --format="json"); then
      echo "  ${repo_id}: !! cannot list images -- skipped (nothing deleted)"
      continue
    fi

    images=$(printf '%s' "${images_json:-[]}" | python3 -c "
import json, sys
imgs = json.load(sys.stdin)
names = set(i['package'] for i in imgs if i.get('package'))
for n in sorted(names):
    print(n)
")

    if [[ -z "${images}" ]]; then
      echo "  ${repo_id}: no images"
      continue
    fi

    while IFS= read -r img_path; do
      [[ -z "${img_path}" ]] && continue
      trim_ar_image "${img_path}" "${repo_id}/${img_path##*/}"
    done <<< "${images}"
  done <<< "${REPOS}"
fi

echo ""

# --- Legacy Container Registry (GCR bridge repos) ---
echo "=== Legacy Container Registry ==="

if ! GCR_JSON=$(gcloud_query "Artifact Registry repositories (GCR bridge)" artifacts repositories list \
  --project="${GOOGLE_CLOUD_PROJECT}" \
  --format="json"); then
  GCR_JSON=""
  GCR_UNREADABLE=1
fi

GCR_REPOS=$(printf '%s' "${GCR_JSON:-[]}" | python3 -c "
import json, sys
proj = sys.argv[1]
for r in json.load(sys.stdin):
    parts = r.get('name','').split('/')
    if len(parts) < 6: continue
    repo_id = parts[5]
    if repo_id.endswith('.gcr.io') or repo_id == 'gcr.io':
        print(repo_id + '/' + proj)
" "${GOOGLE_CLOUD_PROJECT}" || true)

if [[ -n "${GCR_UNREADABLE:-}" ]]; then
  echo "  !! cannot list repositories -- skipping legacy GCR (nothing deleted)"
elif [[ -z "${GCR_REPOS}" ]]; then
  echo "  no GCR bridge repos found"
else
  while IFS= read -r gcr_repo; do
    [[ -z "${gcr_repo}" ]] && continue
    echo "${gcr_repo%%/*}:"
    sweep_gcr_repo "${gcr_repo}" "${KEEP_COUNT}"
  done <<< "${GCR_REPOS}"
fi

echo ""

# --- Secret Manager ---
echo "=== Secret Manager ==="

if ! ALL_SECRETS=$(gcloud_query "Secret Manager secrets" secrets list \
  --project="${GOOGLE_CLOUD_PROJECT}" \
  --format="value(name)"); then
  echo "  !! cannot list secrets -- skipping Secret Manager (nothing destroyed)"
elif [[ -z "${ALL_SECRETS}" ]]; then
  echo "  no secrets found"
else
  while IFS= read -r secret_name; do
    [[ -z "${secret_name}" ]] && continue
    trim_secret_versions "${secret_name}" "${SECRET_KEEP_COUNT}"
  done <<< "${ALL_SECRETS}"
fi

echo ""

# --- Cloud Storage (build-scratch bucket lifecycle) ---
echo "=== Cloud Storage ==="
trim_build_buckets

echo ""
finish
