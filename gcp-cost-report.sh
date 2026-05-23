#!/bin/bash
set -euo pipefail

# =============================================================================
# gcp-cost-report.sh
#
# Reports storage usage and estimated monthly costs for a GCP/Firebase project.
# Auto-detects project type by checking which APIs are enabled, then queries:
#   - Firebase Hosting (all sites → all releases)
#   - Artifact Registry (Docker repos → image sizes)
#   - Cloud Run (service/revision inventory; images billed via AR)
#
# Usage:
#   ./gcp-cost-report.sh <project-id>
#   ./gcp-cost-report.sh <project-id> --dry-run
#
# Pricing used (per GB/month):
#   Firebase Hosting   $0.026   (10 GB free on Blaze plan)
#   Artifact Registry  $0.100   (0.5 GB free per project/month)
# =============================================================================

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  sed -n '3,18p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

PROJECT="${1:?Usage: $0 <project-id> [--dry-run]}"
DRY_RUN=0; [[ "${2:-}" == "--dry-run" ]] && DRY_RUN=1

# ── Colours ───────────────────────────────────────────────────────────────────
BOLD='\033[1m'; BLUE='\033[0;34m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; DIM='\033[2m'; NC='\033[0m'

hdr()  { echo; echo -e "${BOLD}${BLUE}━━━ $* ━━━${NC}"; }
sec()  { echo; echo -e "${BOLD}  ▸ $*${NC}"; }
note() { echo -e "    ${DIM}$*${NC}"; }
ok()   { echo -e "    ${GREEN}✓${NC} $*"; }
warn() { echo -e "    ${YELLOW}⚠${NC}  $*"; }

# ── Python helpers (avoid bc/awk for float math) ──────────────────────────────
bytes_human() { python3 -c "
b=$1
if b>=1073741824: print(f'{b/1073741824:.2f} GB')
elif b>=1048576:  print(f'{b/1048576:.2f} MB')
elif b>=1024:     print(f'{b/1024:.2f} KB')
else:             print(f'{b} B')
"; }

cost() { python3 -c "print(f'{$1 * $2 / 1073741824:.5f}')"; }      # bytes × rate/GB
addcost() { python3 -c "print(f'{float(\"$1\") + float(\"$2\"):.5f}')"; }

# ── Auth ──────────────────────────────────────────────────────────────────────
TOKEN=$(gcloud auth print-access-token 2>/dev/null) || {
  echo "ERROR: Not authenticated. Run: gcloud auth application-default login" >&2
  exit 1
}

firebase_get() {
  curl -sf "$1" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "x-goog-user-project: ${PROJECT}" 2>/dev/null || echo '{}'
}

# ── Detect enabled APIs ───────────────────────────────────────────────────────
hdr "GCP Storage Cost Report: ${PROJECT}"
echo
echo -n "  Detecting enabled APIs..."

ENABLED=$(gcloud services list --enabled \
  --project="${PROJECT}" \
  --format="value(name)" 2>/dev/null | sed 's|.*/||' || true)

has_api() { echo "$ENABLED" | grep -q "^${1}$"; }

HAS_FIREBASE=0; HAS_AR=0; HAS_CR=0
has_api "firebasehosting.googleapis.com" && HAS_FIREBASE=1
has_api "artifactregistry.googleapis.com" && HAS_AR=1
has_api "run.googleapis.com"              && HAS_CR=1

TYPE_LABEL=""
[[ $HAS_FIREBASE -eq 1 ]] && TYPE_LABEL+="Firebase "
[[ $HAS_AR -eq 1 || $HAS_CR -eq 1 ]] && TYPE_LABEL+="Cloud Run/AR"
TYPE_LABEL="${TYPE_LABEL:-unknown}"

echo -e " ${GREEN}${TYPE_LABEL// /, }${NC}"

# Running totals (bytes = integers; costs = floats via python)
FB_BYTES=0;   FB_COST="0.00000"
AR_BYTES=0;   AR_COST="0.00000"

# ── Firebase Hosting ──────────────────────────────────────────────────────────
if [[ $HAS_FIREBASE -eq 1 ]]; then
  sec "Firebase Hosting  (\$0.026/GB/mo)"

  SITES_JSON=$(firebase_get \
    "https://firebasehosting.googleapis.com/v1beta1/projects/${PROJECT}/sites")

  SITE_IDS=$(echo "$SITES_JSON" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for s in d.get('sites',[]): print(s['name'].split('/')[-1])
" 2>/dev/null || true)

  if [[ -z "$SITE_IDS" ]]; then
    note "No Hosting sites found."
  else
    while IFS= read -r site_id; do
      RELEASES_JSON=$(firebase_get \
        "https://firebasehosting.googleapis.com/v1beta1/sites/${site_id}/releases?pageSize=100")

      read -r COUNT BYTES < <(echo "$RELEASES_JSON" | python3 -c "
import json,sys
rs=json.load(sys.stdin).get('releases',[])
total=sum(int(r.get('version',{}).get('versionBytes',0)) for r in rs)
print(len(rs), total)
" 2>/dev/null || echo "0 0")

      HUMAN=$(bytes_human "$BYTES")
      ITEM_COST=$(cost "$BYTES" "0.026")
      printf "    %-42s  %3d releases  %10s  ~\$%s/mo\n" \
        "$site_id" "$COUNT" "$HUMAN" "$ITEM_COST"

      FB_BYTES=$((FB_BYTES + BYTES))
      FB_COST=$(addcost "$FB_COST" "$ITEM_COST")
    done <<< "$SITE_IDS"
  fi
else
  sec "Firebase Hosting"
  note "API not enabled — skipping."
fi

# ── Artifact Registry ─────────────────────────────────────────────────────────
if [[ $HAS_AR -eq 1 ]]; then
  sec "Artifact Registry  (\$0.10/GB/mo)"

  REPOS=$(gcloud artifacts repositories list \
    --project="${PROJECT}" \
    --format="json" 2>/dev/null || echo '[]')

  REPO_LIST=$(echo "$REPOS" | python3 -c "
import json,sys
for r in json.load(sys.stdin):
    name=r['name'].split('/')[-1]
    fmt=r.get('format','?')
    loc=r.get('name','').split('/')[3] if '/locations/' in r.get('name','') else '?'
    print(f'{name}\t{fmt}\t{loc}')
" 2>/dev/null || true)

  if [[ -z "$REPO_LIST" ]]; then
    note "No repositories found."
  else
    while IFS=$'\t' read -r repo_name fmt location; do
      if [[ "$fmt" == "DOCKER" ]]; then
        IMAGE_PATH="${location}-docker.pkg.dev/${PROJECT}/${repo_name}"

        IMAGES_JSON=$(gcloud artifacts docker images list "$IMAGE_PATH" \
          --project="${PROJECT}" \
          --format="json" 2>/dev/null || echo '[]')

        read -r COUNT BYTES < <(echo "$IMAGES_JSON" | python3 -c "
import json,sys
imgs=json.load(sys.stdin)
total=sum(int(i.get('imageSizeBytes',0)) for i in imgs)
print(len(imgs), total)
" 2>/dev/null || echo "0 0")

        HUMAN=$(bytes_human "$BYTES")
        ITEM_COST=$(cost "$BYTES" "0.10")
        printf "    %-42s  %3d images    %10s  ~\$%s/mo\n" \
          "${repo_name} (${location})" "$COUNT" "$HUMAN" "$ITEM_COST"

        AR_BYTES=$((AR_BYTES + BYTES))
        AR_COST=$(addcost "$AR_COST" "$ITEM_COST")
      else
        printf "    %-42s  %-6s repo (size N/A)\n" "${repo_name} (${location})" "$fmt"
      fi
    done <<< "$REPO_LIST"
  fi
else
  sec "Artifact Registry"
  note "API not enabled — skipping."
fi

# ── Cloud Run ─────────────────────────────────────────────────────────────────
if [[ $HAS_CR -eq 1 ]]; then
  sec "Cloud Run  (informational — images billed via Artifact Registry)"

  CR_JSON=$(gcloud run services list \
    --project="${PROJECT}" \
    --format="json" 2>/dev/null || echo '[]')

  SERVICES=$(echo "$CR_JSON" | python3 -c "
import json,sys
for s in json.load(sys.stdin):
    name=s['metadata']['name']
    region=s['metadata'].get('labels',{}).get('cloud.googleapis.com/location','?')
    url=s.get('status',{}).get('url','')
    print(f'{name}\t{region}\t{url}')
" 2>/dev/null || true)

  if [[ -z "$SERVICES" ]]; then
    note "No Cloud Run services found."
  else
    while IFS=$'\t' read -r svc_name region url; do
      REV_COUNT=$(gcloud run revisions list \
        --service="${svc_name}" \
        --region="${region}" \
        --project="${PROJECT}" \
        --format="value(metadata.name)" 2>/dev/null | wc -l | tr -d ' ')
      printf "    %-30s  %-14s  %3d revisions\n" "$svc_name" "$region" "$REV_COUNT"
    done <<< "$SERVICES"
  fi
else
  sec "Cloud Run"
  note "API not enabled — skipping."
fi

# ── Summary ───────────────────────────────────────────────────────────────────
hdr "Summary: ${PROJECT}"

TOTAL_BYTES=$((FB_BYTES + AR_BYTES))
TOTAL_COST=$(addcost "$FB_COST" "$AR_COST")

FB_HUMAN=$(bytes_human "$FB_BYTES")
AR_HUMAN=$(bytes_human "$AR_BYTES")
TOTAL_HUMAN=$(bytes_human "$TOTAL_BYTES")

printf "  %-26s  %10s  ~\$%s/mo\n" "Firebase Hosting:"   "$FB_HUMAN"    "$FB_COST"
printf "  %-26s  %10s  ~\$%s/mo\n" "Artifact Registry:"  "$AR_HUMAN"    "$AR_COST"
echo   "  ──────────────────────────────────────────────────"
printf "  %-26s  %10s  ~\$%s/mo\n" "Total:"              "$TOTAL_HUMAN" "$TOTAL_COST"
echo
note "Rates: Firebase Hosting \$0.026/GB, Artifact Registry \$0.10/GB"
note "Excludes free tiers (10 GB Firebase, 0.5 GB AR/project/month) and egress"
echo
