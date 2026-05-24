#!/bin/bash
set -euo pipefail

# =============================================================================
# Summarize GCS bucket storage for a GCP project.
# Lists every bucket with its size; labels known special buckets
# (GCR artifact storage, App Engine staging/default).
# =============================================================================

for _arg in "$@"; do
  if [[ "$_arg" == "-h" || "$_arg" == "--help" ]]; then
    cat <<'EOF'
Usage: gcp-bucket-summary <project-id>

List all GCS buckets in a project with storage sizes.
Known special buckets (GCR artifacts, App Engine) are labeled.
EOF
    exit 0
  fi
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/.env" ]] && source "${SCRIPT_DIR}/.env"

PROJECT_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
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

PROJECT="${PROJECT_ARG:-${GOOGLE_CLOUD_PROJECT:-}}"
PROJECT="${PROJECT:?Set GOOGLE_CLOUD_PROJECT in .env, the environment, or pass as first argument}"

BOLD='\033[1m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

classify() {
  local name="$1"
  case "${name}" in
    "${PROJECT}.appspot.com")                   echo "App Engine default bucket" ;;
    "staging.${PROJECT}.appspot.com")           echo "App Engine deployment staging" ;;
    "artifacts.${PROJECT}.appspot.com")         echo "GCR artifact storage (gcr.io)" ;;
    "us.artifacts.${PROJECT}.appspot.com")      echo "GCR artifact storage (us.gcr.io)" ;;
    "eu.artifacts.${PROJECT}.appspot.com")      echo "GCR artifact storage (eu.gcr.io)" ;;
    "asia.artifacts.${PROJECT}.appspot.com")    echo "GCR artifact storage (asia.gcr.io)" ;;
    *".artifacts.${PROJECT}.appspot.com")       echo "GCR artifact storage" ;;
    *)                                          echo "" ;;
  esac
}

fmt_size() {
  python3 -c "
b = int('$1')
for u, d in [('TB',1<<40),('GB',1<<30),('MB',1<<20),('KB',1<<10)]:
    if b >= d: print(f'{b/d:8.2f} {u}'); break
else: print(f'{b:8} B ')
"
}

echo ""
echo -e "${BOLD}━━━ GCS Bucket Summary: ${PROJECT} ━━━${NC}"
echo ""
printf "  Listing buckets..."

BUCKETS=$(gcloud storage buckets list \
  --project="${PROJECT}" \
  --format="value(name)" 2>/dev/null || true)

if [[ -z "${BUCKETS}" ]]; then
  echo ""
  echo "  No buckets found (or missing storage.buckets.list permission)."
  exit 0
fi

BUCKET_COUNT=$(wc -l <<< "${BUCKETS}" | tr -d ' ')
echo -e " ${GREEN}${BUCKET_COUNT} found${NC}"
echo ""

SPECIAL_LINES=()
USER_LINES=()
TOTAL_BYTES=0

while IFS= read -r bucket; do
  [[ -z "${bucket}" ]] && continue
  bname="${bucket}"
  label=$(classify "${bname}")

  printf "  scanning %-50s\r" "${bname:0:50}"

  raw=$(gcloud storage du "gs://${bucket}" --summarize 2>/dev/null || echo "0")
  bytes=$(awk '{print $1}' <<< "${raw}")
  [[ -z "${bytes}" || ! "${bytes}" =~ ^[0-9]+$ ]] && bytes=0

  TOTAL_BYTES=$(python3 -c "print(${TOTAL_BYTES} + ${bytes})")
  size=$(fmt_size "${bytes}")

  if [[ -n "${label}" ]]; then
    SPECIAL_LINES+=("$(printf "    %-46s  %s  %s" "${bname}" "${size}" "${label}")")
  else
    USER_LINES+=("$(printf "    %-46s  %s" "${bname}" "${size}")")
  fi
done <<< "${BUCKETS}"

printf "%80s\r" ""  # clear the scanning line

if [[ ${#SPECIAL_LINES[@]} -gt 0 ]]; then
  echo -e "  ${BOLD}▸ Special buckets${NC}"
  for line in "${SPECIAL_LINES[@]}"; do echo "${line}"; done
  echo ""
fi

if [[ ${#USER_LINES[@]} -gt 0 ]]; then
  echo -e "  ${BOLD}▸ User buckets${NC}"
  for line in "${USER_LINES[@]}"; do echo "${line}"; done
  echo ""
fi

TOTAL_SIZE=$(fmt_size "${TOTAL_BYTES}")
echo "  ──────────────────────────────────────────────────"
printf "  Total: %s across %s bucket(s)\n" "${TOTAL_SIZE}" "${BUCKET_COUNT}"
echo ""
