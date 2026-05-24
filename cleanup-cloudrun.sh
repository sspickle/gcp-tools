#!/bin/bash
set -euo pipefail

# =============================================================================
# Clean up old Cloud Run revisions and Artifact Registry images,
# keeping the most recent KEEP_COUNT of each.
#
# Usage:
#   cleanup-cloudrun [PROJECT_ID] [--dry-run]          # auto-discover all
#   cleanup-cloudrun [PROJECT_ID] [--dry-run]          # targeted if SERVICE_NAME set
#   cleanup-cloudrun --sweep-repo                      # legacy GCR
#
# Auto-discover mode (default when SERVICE_NAME is not set):
#   Finds all Cloud Run services and AR repos in the project and trims each.
#   Required: GOOGLE_CLOUD_PROJECT (or pass as first argument)
#   Optional: KEEP_COUNT (default: 3)
#
# Targeted mode (when SERVICE_NAME is set in .env or environment):
#   Trims a specific Cloud Run service and its AR image.
#   Required: GOOGLE_CLOUD_PROJECT, SERVICE_NAME, REPO_NAME
#   Optional: KEEP_COUNT (default: 3), GOOGLE_CLOUD_REGION (default: us-central1),
#             IMAGE_NAME (default: SERVICE_NAME)
#
# --sweep-repo mode (legacy Container Registry):
#   Sweeps every image in a GCR repo, keeping the newest KEEP_COUNT versions.
#   Required: REPOSITORY (e.g. us.gcr.io/my-project)
#   Optional: KEEP_COUNT (default: 1)
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
  Finds all Cloud Run services and AR repos in the project and trims each.
  Required: GOOGLE_CLOUD_PROJECT (or pass as first argument)
  Optional: KEEP_COUNT (default: 3), DRY_RUN=1

Targeted mode (when SERVICE_NAME is set in .env or environment):
  Trims a specific Cloud Run service and its AR image.
  Required: GOOGLE_CLOUD_PROJECT, SERVICE_NAME, REPO_NAME
  Optional: KEEP_COUNT (default: 3), GOOGLE_CLOUD_REGION (default: us-central1),
            IMAGE_NAME (default: SERVICE_NAME)

--sweep-repo mode (legacy Container Registry):
  Sweeps every image in a GCR repository, keeping the newest KEEP_COUNT versions.
  Required: REPOSITORY (e.g. us.gcr.io/my-project)
  Optional: KEEP_COUNT (default: 1)

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

  IMAGE_NAMES=$(gcloud container images list \
    --repository="${REPOSITORY}" \
    --format="value(name)" 2>/dev/null || true)

  if [[ -z "${IMAGE_NAMES}" ]]; then
    echo "No images found in ${REPOSITORY}"
    exit 0
  fi

  while IFS= read -r image_url; do
    image_name="${image_url##*/}"
    echo "=== ${image_name} ==="

    DIGESTS=$(gcloud container images list-tags "${image_url}" \
      --sort-by="~timestamp" \
      --format="value(digest)" 2>/dev/null || true)

    if [[ -z "${DIGESTS}" ]]; then
      echo "  no versions found"
      continue
    fi

    COUNT=0
    while IFS= read -r digest; do
      [[ -z "${digest}" ]] && continue
      COUNT=$((COUNT + 1))
      [[ "${digest}" != sha256:* ]] && digest="sha256:${digest}"
      if [[ ${COUNT} -le ${KEEP_COUNT} ]]; then
        echo "  keeping  ${digest:0:19}..."
      else
        echo "  deleting ${digest:0:19}..."
        if [[ "${DRY_RUN}" != "1" ]]; then
          gcloud container images delete "${image_url}@${digest}" \
            --force-delete-tags \
            --quiet 2>/dev/null || echo "    (skipped)"
        fi
      fi
    done <<< "${DIGESTS}"
  done <<< "${IMAGE_NAMES}"

  echo ""
  echo "=== Done ==="
  exit 0
fi

# --- resolve project and common config ---
GOOGLE_CLOUD_PROJECT="${PROJECT_ARG:-${GOOGLE_CLOUD_PROJECT:-}}"
GOOGLE_CLOUD_PROJECT="${GOOGLE_CLOUD_PROJECT:?Set GOOGLE_CLOUD_PROJECT in .env, the environment, or pass as first argument}"
KEEP_COUNT="${KEEP_COUNT:-3}"

[[ "${DRY_RUN}" == "1" ]] && echo "--- DRY RUN — nothing will be deleted ---"
echo "Project: ${GOOGLE_CLOUD_PROJECT}"
echo "Keeping last ${KEEP_COUNT} revisions/images per service"
echo ""

# ---------------------------------------------------------------------------
# Helper: trim old revisions for one Cloud Run service
# ---------------------------------------------------------------------------
trim_revisions() {
  local svc="$1" region="$2"
  echo "  revisions: ${svc} (${region})"

  local revisions
  revisions=$(gcloud run revisions list \
    --service="${svc}" \
    --region="${region}" \
    --project="${GOOGLE_CLOUD_PROJECT}" \
    --sort-by="~metadata.creationTimestamp" \
    --format="value(metadata.name)" 2>/dev/null || true)

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
        gcloud run revisions delete "${rev}" \
          --region="${region}" \
          --project="${GOOGLE_CLOUD_PROJECT}" \
          --quiet 2>/dev/null || echo "      (skipped — may be serving traffic)"
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
  digests=$(gcloud artifacts docker images list "${img_path}" \
    --format="value(createTime,version)" \
    --project="${GOOGLE_CLOUD_PROJECT}" 2>/dev/null \
    | grep -v "^Listing" | sort -r | awk '{print $2}' || true)

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
        gcloud artifacts docker images delete \
          "${img_path}@${digest}" \
          --delete-tags \
          --async \
          --project="${GOOGLE_CLOUD_PROJECT}" \
          --quiet 2>/dev/null || echo "      (skipped)"
      fi
    fi
  done <<< "${digests}"
}

# ---------------------------------------------------------------------------
# Helper: sweep old versions of every image in a GCR repository
# ---------------------------------------------------------------------------
sweep_gcr_repo() {
  local repository="$1"

  local image_names
  image_names=$(gcloud container images list \
    --repository="${repository}" \
    --format="value(name)" 2>/dev/null || true)

  if [[ -z "${image_names}" ]]; then
    echo "  (no images)"
    return
  fi

  while IFS= read -r image_url; do
    local image_name="${image_url##*/}"
    echo "  ${image_name}"

    local digests
    digests=$(gcloud container images list-tags "${image_url}" \
      --sort-by="~timestamp" \
      --format="value(digest)" 2>/dev/null || true)

    if [[ -z "${digests}" ]]; then
      echo "    no versions found"
      continue
    fi

    local count=0
    while IFS= read -r digest; do
      [[ -z "${digest}" ]] && continue
      count=$((count + 1))
      [[ "${digest}" != sha256:* ]] && digest="sha256:${digest}"
      if [[ ${count} -le ${KEEP_COUNT} ]]; then
        echo "    keeping  ${digest:0:19}..."
      else
        echo "    deleting ${digest:0:19}..."
        if [[ "${DRY_RUN}" != "1" ]]; then
          gcloud container images delete "${image_url}@${digest}" \
            --force-delete-tags \
            --quiet 2>/dev/null || echo "      (skipped)"
        fi
      fi
    done <<< "${digests}"
  done <<< "${image_names}"
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
  echo ""
  echo "=== Done ==="
  exit 0
fi

# ---------------------------------------------------------------------------
# Auto-discover mode: enumerate all Cloud Run services and AR images
# ---------------------------------------------------------------------------
echo "Mode: auto-discover"
echo ""

# --- Cloud Run ---
echo "=== Cloud Run ==="

SERVICES=$(gcloud run services list \
  --project="${GOOGLE_CLOUD_PROJECT}" \
  --format="csv[no-heading](metadata.name,metadata.labels.'cloud.googleapis.com/location')" \
  2>/dev/null || true)

if [[ -z "${SERVICES}" ]]; then
  echo "  no services found"
else
  while IFS=, read -r svc svc_region; do
    [[ -z "${svc}" ]] && continue
    trim_revisions "${svc}" "${svc_region}"
  done <<< "${SERVICES}"
fi

echo ""

# --- Artifact Registry ---
echo "=== Artifact Registry ==="

REPOS=$(gcloud artifacts repositories list \
  --project="${GOOGLE_CLOUD_PROJECT}" \
  --format="json" 2>/dev/null \
  | python3 -c "
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

if [[ -z "${REPOS}" ]]; then
  echo "  no repositories found"
else
  while IFS=, read -r repo_location repo_id; do
    [[ -z "${repo_id}" ]] && continue
    image_base="${repo_location}-docker.pkg.dev/${GOOGLE_CLOUD_PROJECT}/${repo_id}"

    images=$(gcloud artifacts docker images list "${image_base}" \
      --project="${GOOGLE_CLOUD_PROJECT}" \
      --format="value(image)" \
      2>/dev/null | grep -v "^Listing" | sort -u || true)

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

GCR_REPOS=$(gcloud artifacts repositories list \
  --project="${GOOGLE_CLOUD_PROJECT}" \
  --format="json" 2>/dev/null \
  | python3 -c "
import json, sys
proj = sys.argv[1]
for r in json.load(sys.stdin):
    parts = r.get('name','').split('/')
    if len(parts) < 6: continue
    repo_id = parts[5]
    if repo_id.endswith('.gcr.io') or repo_id == 'gcr.io':
        print(repo_id + '/' + proj)
" "${GOOGLE_CLOUD_PROJECT}" || true)

if [[ -z "${GCR_REPOS}" ]]; then
  echo "  no GCR bridge repos found"
else
  while IFS= read -r gcr_repo; do
    [[ -z "${gcr_repo}" ]] && continue
    echo "${gcr_repo%%/*}:"
    sweep_gcr_repo "${gcr_repo}"
  done <<< "${GCR_REPOS}"
fi

echo ""
echo "=== Done ==="
