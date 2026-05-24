#!/bin/bash
set -euo pipefail

# =============================================================================
# Clean up old Cloud Run revisions and Artifact Registry images,
# keeping the most recent KEEP_COUNT of each.
# =============================================================================
#
# Usage:
#   ./cleanup-cloudrun.sh
#
# Required:
#   export GOOGLE_CLOUD_PROJECT=my-project
#   export SERVICE_NAME=my-service
#   export REPO_NAME=my-repo
#
# Optional:
#   export KEEP_COUNT=3           # revisions/images to keep (default: 3)
#   export DRY_RUN=1              # print what would be deleted without deleting

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage: cleanup-cloudrun.sh [--sweep-repo]

Delete old Cloud Run revisions and Artifact Registry images,
keeping the most recent KEEP_COUNT of each.

Default mode (Cloud Run + Artifact Registry):
  Required: GOOGLE_CLOUD_PROJECT, SERVICE_NAME, REPO_NAME
  Optional: KEEP_COUNT (default: 3), GOOGLE_CLOUD_REGION (default: us-central1),
            IMAGE_NAME (default: SERVICE_NAME, set when AR image name differs from service name)

--sweep-repo mode (legacy Container Registry):
  Sweeps every image in a GCR repository, keeping the newest KEEP_COUNT
  versions of each image. Uses gcloud container images (not AR API).
  Required: REPOSITORY  (e.g. us.gcr.io/my-project)
  Optional: KEEP_COUNT  (default: 1)

Common:
  DRY_RUN=1   Print what would be deleted without deleting
EOF
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  source "${SCRIPT_DIR}/.env"
fi

# ---------------------------------------------------------------------------
# --sweep-repo mode: keep newest KEEP_COUNT versions of every image in a
# legacy Container Registry repository (uses gcloud container images, not AR)
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--sweep-repo" ]]; then
  REPOSITORY="${REPOSITORY:?Set REPOSITORY (e.g. us.gcr.io/PROJECT) in .env or environment}"
  KEEP_COUNT="${KEEP_COUNT:-1}"
  DRY_RUN="${DRY_RUN:-0}"

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
      # Ensure digest has sha256: prefix for the delete command
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

GOOGLE_CLOUD_PROJECT="${GOOGLE_CLOUD_PROJECT:?Set GOOGLE_CLOUD_PROJECT in .env or the environment}"
GOOGLE_CLOUD_REGION="${GOOGLE_CLOUD_REGION:-us-central1}"
SERVICE_NAME="${SERVICE_NAME:?Set SERVICE_NAME in .env or the environment}"
REPO_NAME="${REPO_NAME:?Set REPO_NAME in .env or the environment}"
KEEP_COUNT="${KEEP_COUNT:-3}"
DRY_RUN="${DRY_RUN:-0}"
IMAGE_NAME="${IMAGE_NAME:-${SERVICE_NAME}}"
IMAGE_PATH="${GOOGLE_CLOUD_REGION}-docker.pkg.dev/${GOOGLE_CLOUD_PROJECT}/${REPO_NAME}/${IMAGE_NAME}"

if [[ "${DRY_RUN}" == "1" ]]; then
  echo "--- DRY RUN — nothing will be deleted ---"
fi

echo "Project: ${GOOGLE_CLOUD_PROJECT}"
echo "Region:  ${GOOGLE_CLOUD_REGION}"
echo "Service: ${SERVICE_NAME}"
echo "Keeping last ${KEEP_COUNT} revisions and images"
echo ""

# ---------------------------------------------------------------------------
# Cloud Run revisions
# ---------------------------------------------------------------------------
echo "=== Cloud Run revisions ==="

# List all revisions sorted newest-first; skip the header line
ALL_REVISIONS=$(gcloud run revisions list \
  --service="${SERVICE_NAME}" \
  --region="${GOOGLE_CLOUD_REGION}" \
  --project="${GOOGLE_CLOUD_PROJECT}" \
  --sort-by="~metadata.creationTimestamp" \
  --format="value(metadata.name)" 2>/dev/null || true)

if [[ -z "${ALL_REVISIONS}" ]]; then
  echo "No revisions found."
else
  REVISION_COUNT=0
  while IFS= read -r revision; do
    REVISION_COUNT=$((REVISION_COUNT + 1))
    if [[ ${REVISION_COUNT} -le ${KEEP_COUNT} ]]; then
      echo "  keeping  ${revision}"
    else
      echo "  deleting ${revision}"
      if [[ "${DRY_RUN}" != "1" ]]; then
        gcloud run revisions delete "${revision}" \
          --region="${GOOGLE_CLOUD_REGION}" \
          --project="${GOOGLE_CLOUD_PROJECT}" \
          --quiet 2>/dev/null || echo "    (skipped — may be serving traffic)"
      fi
    fi
  done <<< "${ALL_REVISIONS}"
fi

echo ""

# ---------------------------------------------------------------------------
# Artifact Registry images
# ---------------------------------------------------------------------------
echo "=== Artifact Registry images ==="

# List digests sorted newest-first
ALL_DIGESTS=$(gcloud artifacts docker images list "${IMAGE_PATH}" \
  --format="value(createTime,version)" \
  --project="${GOOGLE_CLOUD_PROJECT}" 2>/dev/null \
  | grep -v "^Listing" | sort -r | awk '{print $2}' || true)

if [[ -z "${ALL_DIGESTS}" ]]; then
  echo "No images found."
else
  IMAGE_COUNT=0
  while IFS= read -r digest; do
    [[ -z "${digest}" ]] && continue
    IMAGE_COUNT=$((IMAGE_COUNT + 1))
    if [[ ${IMAGE_COUNT} -le ${KEEP_COUNT} ]]; then
      echo "  keeping  ${digest:0:19}..."
    else
      echo "  deleting ${digest:0:19}..."
      if [[ "${DRY_RUN}" != "1" ]]; then
        gcloud artifacts docker images delete \
          "${IMAGE_PATH}@${digest}" \
          --delete-tags \
          --async \
          --project="${GOOGLE_CLOUD_PROJECT}" \
          --quiet 2>/dev/null || echo "    (skipped)"
      fi
    fi
  done <<< "${ALL_DIGESTS}"
fi

echo ""
echo "=== Done ==="
