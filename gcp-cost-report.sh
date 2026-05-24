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
#   - App Engine (service/version inventory + deployment bucket storage)
#   - Cloud Datastore (entity + index storage via __Stat_Total__)
#   - Compute Engine (instances, persistent disks, reserved IPs)
#
# Usage:
#   ./gcp-cost-report.sh <project-id> [--billing-csv <file>] [--dry-run]
#
# Pass --billing-csv with a CSV downloaded from GCP Billing > Reports to see
# a ground-truth cost summary alongside the script's per-resource analysis.
#
# Pricing used (per GB/month):
#   Firebase Hosting   $0.026   (10 GB free on Blaze plan)
#   Artifact Registry  $0.100   (0.5 GB free per project/month)
#   App Engine (GCS)   $0.020   (deployment bucket; Standard storage rate)
#   Cloud Datastore    $0.108   (entities + index storage; stats updated ~daily)
#   Compute Engine     $0.040–$0.170/GB  (disk type dependent; IPs $0.010/hr unused)
# =============================================================================

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  awk '/^# ==/{f=!f;next} f{sub(/^# ?/,"");print}' "$0"
  exit 0
fi

PROJECT="${1:?Usage: $0 <project-id> [--billing-csv <file>] [--dry-run]}"
shift
DRY_RUN=0
BILLING_CSV=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)     awk '/^# ==/{f=!f;next} f{sub(/^# ?/,"");print}' "$0"; exit 0 ;;
    --dry-run)     DRY_RUN=1 ;;
    --billing-csv) shift; BILLING_CSV="${1:?--billing-csv requires a file path}" ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

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

HAS_FIREBASE=0; HAS_AR=0; HAS_CR=0; HAS_AE=0; HAS_DS=0; HAS_CE=0
has_api "firebasehosting.googleapis.com" && HAS_FIREBASE=1
has_api "artifactregistry.googleapis.com" && HAS_AR=1
has_api "run.googleapis.com"              && HAS_CR=1
has_api "appengine.googleapis.com"        && HAS_AE=1
has_api "datastore.googleapis.com"        && HAS_DS=1
has_api "compute.googleapis.com"          && HAS_CE=1

TYPE_LABEL=""
[[ $HAS_FIREBASE -eq 1 ]] && TYPE_LABEL+="Firebase,"
[[ $HAS_AR -eq 1 || $HAS_CR -eq 1 ]] && TYPE_LABEL+="Cloud Run/AR,"
[[ $HAS_AE -eq 1 ]] && TYPE_LABEL+="App Engine,"
[[ $HAS_DS -eq 1 ]] && TYPE_LABEL+="Datastore,"
[[ $HAS_CE -eq 1 ]] && TYPE_LABEL+="Compute Engine,"
TYPE_LABEL="${TYPE_LABEL%,}"
TYPE_LABEL="${TYPE_LABEL:-unknown}"

echo -e " ${GREEN}${TYPE_LABEL}${NC}"

# Running totals (bytes = integers; costs = floats via python)
FB_BYTES=0;        FB_COST="0.00000"
AR_BYTES=0;        AR_COST="0.00000"
GCS_BYTES=0;       GCS_COST="0.00000"
DS_BYTES=0;        DS_COST="0.00000"
GCE_DISK_BYTES=0;  GCE_DISK_COST="0.00000"
GCE_IP_COST="0.00000"

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
    gcr=1 if 'gcr.io' in name else 0
    print(f'{name}\t{fmt}\t{loc}\t{gcr}')
" 2>/dev/null || true)

  if [[ -z "$REPO_LIST" ]]; then
    note "No repositories found."
  else
    while IFS=$'\t' read -r repo_name fmt location is_gcr; do
      if [[ "$fmt" == "DOCKER" ]]; then
        if [[ "$is_gcr" == "1" ]]; then
          printf "    %-42s  legacy Container Registry — sizes stored in GCS (not available via AR API)\n" \
            "${repo_name} (${location})"
          continue
        fi
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

# ── App Engine ────────────────────────────────────────────────────────────────
if [[ $HAS_AE -eq 1 ]]; then
  sec "App Engine  (informational + deployment storage \$0.020/GB/mo)"

  SERVICES_JSON=$(gcloud app services list \
    --project="${PROJECT}" \
    --format="json" 2>/dev/null || echo '[]')

  SVCLIST=$(echo "$SERVICES_JSON" | python3 -c "
import json,sys
for s in json.load(sys.stdin): print(s['id'])
" 2>/dev/null || true)

  if [[ -z "$SVCLIST" ]]; then
    note "No App Engine services found."
  else
    while IFS= read -r svc_id; do
      VER_COUNT=$(gcloud app versions list \
        --service="${svc_id}" \
        --project="${PROJECT}" \
        --format="value(id)" 2>/dev/null | wc -l | tr -d ' ')
      printf "    %-30s  %3d versions\n" "$svc_id" "$VER_COUNT"
    done <<< "$SVCLIST"

    BUCKET_BYTES=$(python3 -c "
import json, urllib.request, urllib.parse
token='${TOKEN}'; project='${PROJECT}'
bucket='staging.'+project+'.appspot.com'
total=0; page_token=''
while True:
    params={'fields':'nextPageToken,items(size)','maxResults':'1000'}
    if page_token: params['pageToken']=page_token
    url='https://storage.googleapis.com/storage/v1/b/'+bucket+'/o?'+urllib.parse.urlencode(params)
    req=urllib.request.Request(url,headers={'Authorization':'Bearer '+token,'x-goog-user-project':project})
    try:
        with urllib.request.urlopen(req,timeout=10) as r: d=json.loads(r.read())
    except Exception: break
    for item in d.get('items',[]): total+=int(item.get('size',0))
    page_token=d.get('nextPageToken','')
    if not page_token: break
print(total)
" 2>/dev/null || echo "0")
    BUCKET_BYTES=${BUCKET_BYTES:-0}

    if [[ "$BUCKET_BYTES" -gt 0 ]]; then
      HUMAN=$(bytes_human "$BUCKET_BYTES")
      ITEM_COST=$(cost "$BUCKET_BYTES" "0.020")
      printf "    %-42s  %10s  ~\$%s/mo\n" "deployment bucket" "$HUMAN" "$ITEM_COST"
      GCS_BYTES=$((GCS_BYTES + BUCKET_BYTES))
      GCS_COST=$(addcost "$GCS_COST" "$ITEM_COST")
    else
      note "Deployment bucket empty or not found (staging.${PROJECT}.appspot.com)."
    fi
  fi
else
  sec "App Engine"
  note "API not enabled — skipping."
fi

# ── Cloud Datastore ───────────────────────────────────────────────────────────
if [[ $HAS_DS -eq 1 ]]; then
  sec "Cloud Datastore  (\$0.108/GB/mo)"

  DS_STATS=$(curl -sf \
    -X POST \
    "https://datastore.googleapis.com/v1/projects/${PROJECT}:runQuery" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -H "x-goog-user-project: ${PROJECT}" \
    -d '{"gqlQuery":{"queryString":"SELECT * FROM __Stat_Total__ ORDER BY timestamp DESC LIMIT 1"}}' \
    2>/dev/null || echo '{}')

  read -r DS_ENTITY_COUNT DS_BYTES_RAW < <(echo "$DS_STATS" | python3 -c "
import json,sys
d=json.load(sys.stdin)
results=d.get('batch',{}).get('entityResults',[])
if not results:
    print(0, 0)
else:
    props=results[0]['entity']['properties']
    count=int(props.get('count',{}).get('integerValue',0))
    b=int(props.get('bytes',{}).get('integerValue',0))
    bi=int(props.get('builtin_index_bytes',{}).get('integerValue',0))
    ci=int(props.get('composite_index_bytes',{}).get('integerValue',0))
    print(count, b+bi+ci)
" 2>/dev/null || echo "0 0")

  if [[ "${DS_BYTES_RAW:-0}" -gt 0 ]]; then
    HUMAN=$(bytes_human "$DS_BYTES_RAW")
    ITEM_COST=$(cost "$DS_BYTES_RAW" "0.108")
    printf "    %-42s  %6d entities  %10s  ~\$%s/mo\n" \
      "default database" "$DS_ENTITY_COUNT" "$HUMAN" "$ITEM_COST"
    note "(includes entities + index storage; stats updated ~daily)"
    DS_BYTES=$((DS_BYTES + DS_BYTES_RAW))
    DS_COST=$(addcost "$DS_COST" "$ITEM_COST")
  else
    note "No Datastore stats found (may be empty or stats not yet generated)."
  fi
else
  sec "Cloud Datastore"
  note "API not enabled — skipping."
fi

# ── Compute Engine ───────────────────────────────────────────────────────────
if [[ $HAS_CE -eq 1 ]]; then
  sec "Compute Engine"

  # Instances (informational — compute costs depend on uptime)
  CE_INSTANCES=$(gcloud compute instances list \
    --project="${PROJECT}" \
    --format="json" 2>/dev/null || echo '[]')

  INST_LIST=$(echo "$CE_INSTANCES" | python3 -c "
import json,sys
for i in json.load(sys.stdin):
    name=i['name']
    zone=i['zone'].split('/')[-1]
    mtype=i['machineType'].split('/')[-1]
    status=i['status']
    print(f'{name}\t{zone}\t{mtype}\t{status}')
" 2>/dev/null || true)

  echo
  if [[ -z "$INST_LIST" ]]; then
    note "No instances."
  else
    printf "    %-28s  %-22s  %-16s  %s\n" "Instance" "Zone" "Type" "Status"
    while IFS=$'\t' read -r name zone mtype status; do
      printf "    %-28s  %-22s  %-16s  %s\n" "$name" "$zone" "$mtype" "$status"
    done <<< "$INST_LIST"
  fi

  # Persistent disks — all cost money; orphaned ones are pure waste
  CE_DISKS=$(gcloud compute disks list \
    --project="${PROJECT}" \
    --format="json" 2>/dev/null || echo '[]')

  DISK_LIST=$(echo "$CE_DISKS" | python3 -c "
import json,sys
PRICES={'pd-standard':0.040,'pd-ssd':0.170,'pd-balanced':0.100,'pd-extreme':0.125}
for d in json.load(sys.stdin):
    name=d['name']
    size=int(d.get('sizeGb',0))
    dtype=d.get('type','?').split('/')[-1]
    zone=d.get('zone','?').split('/')[-1]
    users=len(d.get('users',[]))
    price=PRICES.get(dtype,0.040)
    monthly=size*price
    orphan=1 if users==0 else 0
    print(f'{name}\t{zone}\t{size}\t{dtype}\t{monthly:.5f}\t{orphan}')
" 2>/dev/null || true)

  echo
  if [[ -z "$DISK_LIST" ]]; then
    note "No persistent disks."
  else
    printf "    %-28s  %-22s  %6s  %-16s  %10s\n" "Disk" "Zone" "Size" "Type" "Cost/mo"
    while IFS=$'\t' read -r name zone size dtype monthly orphan; do
      DISK_BYTES_VAL=$(python3 -c "print(int(${size} * 1073741824))")
      GCE_DISK_BYTES=$((GCE_DISK_BYTES + DISK_BYTES_VAL))
      GCE_DISK_COST=$(addcost "$GCE_DISK_COST" "$monthly")
      if [[ "$orphan" == "1" ]]; then
        printf "    %-28s  %-22s  %5sGB  %-16s  ~\$%s/mo" "$name" "$zone" "$size" "$dtype" "$monthly"
        echo -e "  ${YELLOW}← no instance attached${NC}"
      else
        printf "    %-28s  %-22s  %5sGB  %-16s  ~\$%s/mo\n" "$name" "$zone" "$size" "$dtype" "$monthly"
      fi
    done <<< "$DISK_LIST"
  fi

  # Reserved static IPs — unused ones bill at ~$0.010/hr
  CE_IPS=$(gcloud compute addresses list \
    --project="${PROJECT}" \
    --format="json" 2>/dev/null || echo '[]')

  IP_LIST=$(echo "$CE_IPS" | python3 -c "
import json,sys
for a in json.load(sys.stdin):
    name=a['name']
    region=a.get('region','global').split('/')[-1] if 'region' in a else 'global'
    addr=a.get('address','?')
    status=a.get('status','?')
    users=len(a.get('users',[]))
    unused=1 if status=='RESERVED' and users==0 else 0
    print(f'{name}\t{region}\t{addr}\t{status}\t{unused}')
" 2>/dev/null || true)

  echo
  if [[ -z "$IP_LIST" ]]; then
    note "No reserved static IPs."
  else
    IP_MONTHLY="7.20000"  # $0.010/hr × 24h × 30d
    printf "    %-28s  %-14s  %-16s  %s\n" "IP Name" "Region" "Address" "Status"
    while IFS=$'\t' read -r name region addr status unused; do
      printf "    %-28s  %-14s  %-16s  %-10s" "$name" "$region" "$addr" "$status"
      if [[ "$unused" == "1" ]]; then
        echo -e "  ${YELLOW}← unused  ~\$${IP_MONTHLY}/mo${NC}"
        GCE_IP_COST=$(addcost "$GCE_IP_COST" "$IP_MONTHLY")
      else
        echo
      fi
    done <<< "$IP_LIST"
  fi
else
  sec "Compute Engine"
  note "API not enabled — skipping."
fi

# ── Billing CSV context (optional) ───────────────────────────────────────────
if [[ -n "$BILLING_CSV" ]]; then
  if [[ ! -f "$BILLING_CSV" ]]; then
    warn "Billing CSV not found: $BILLING_CSV"
  else
    hdr "Billing Context (from CSV)"
    python3 -c "
import csv, sys

COVERED = {'Firebase Hosting', 'Artifact Registry', 'Cloud Run',
           'App Engine', 'Cloud Datastore', 'Compute Engine', 'Cloud Storage'}

rows = []
with open(sys.argv[1]) as f:
    for row in csv.DictReader(f):
        service = row.get('Service description', '').strip()
        cost    = float(row.get('Subtotal (\$)', row.get('Cost (\$)', '0')) or 0)
        change  = row.get('Percent change in subtotal compared to previous period', '').strip()
        if service:
            rows.append((cost, service, change))

rows.sort(reverse=True)
total = sum(c for c, _, _ in rows)

print()
print('  NOTE: CSV covers ALL projects in this billing account.')
print('        Costs here may include projects other than the one being analyzed.')
print()
print(f'  {\"Service\":<30}  {\"Cost\":>8}  {\"Change\":>8}')
print(f'  {\"-\"*30}  {\"-\"*8}  {\"-\"*8}')
for cost, service, change in rows:
    flag = '' if any(c in service for c in COVERED) else '  ← not analyzed by this script'
    print(f'  {service:<30}  \${cost:>7.2f}  {change:>8}{flag}')
print(f'  {\"-\"*30}  {\"-\"*8}')
print(f'  {\"Total\":<30}  \${total:>7.2f}')
print()
" "$BILLING_CSV" 2>/dev/null || warn "Could not parse billing CSV — check format."
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
hdr "Summary: ${PROJECT}"

GCE_TOTAL_COST=$(addcost "$GCE_DISK_COST" "$GCE_IP_COST")

TOTAL_BYTES=$((FB_BYTES + AR_BYTES + GCS_BYTES + DS_BYTES + GCE_DISK_BYTES))
TOTAL_COST=$(addcost "$FB_COST" "$AR_COST")
TOTAL_COST=$(addcost "$TOTAL_COST" "$GCS_COST")
TOTAL_COST=$(addcost "$TOTAL_COST" "$DS_COST")
TOTAL_COST=$(addcost "$TOTAL_COST" "$GCE_TOTAL_COST")

FB_HUMAN=$(bytes_human "$FB_BYTES")
AR_HUMAN=$(bytes_human "$AR_BYTES")
GCS_HUMAN=$(bytes_human "$GCS_BYTES")
DS_HUMAN=$(bytes_human "$DS_BYTES")
GCE_HUMAN=$(bytes_human "$GCE_DISK_BYTES")
TOTAL_HUMAN=$(bytes_human "$TOTAL_BYTES")

printf "  %-26s  %10s  ~\$%s/mo\n" "Firebase Hosting:"    "$FB_HUMAN"    "$FB_COST"
printf "  %-26s  %10s  ~\$%s/mo\n" "Artifact Registry:"   "$AR_HUMAN"    "$AR_COST"
printf "  %-26s  %10s  ~\$%s/mo\n" "App Engine (GCS):"    "$GCS_HUMAN"   "$GCS_COST"
printf "  %-26s  %10s  ~\$%s/mo\n" "Cloud Datastore:"     "$DS_HUMAN"    "$DS_COST"
printf "  %-26s  %10s  ~\$%s/mo\n" "Compute Engine:"      "$GCE_HUMAN"   "$GCE_TOTAL_COST"
echo   "  ──────────────────────────────────────────────────"
printf "  %-26s  %10s  ~\$%s/mo\n" "Total:"               "$TOTAL_HUMAN" "$TOTAL_COST"
echo
note "CE includes all persistent disk storage + unused reserved IPs; instance compute not estimated"
note "Rates: Firebase \$0.026/GB, AR \$0.10/GB, GCS \$0.020/GB, Datastore \$0.108/GB, CE disk \$0.04–\$0.17/GB"
note "Excludes free tiers and egress; Datastore figures updated ~daily"
echo
