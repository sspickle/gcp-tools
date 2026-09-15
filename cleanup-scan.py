#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.8"
# dependencies = []
# ///
"""cleanup-scan — triage which GCP projects would repay a cleanup-cloudrun run.

Read-only fleet scanner. It NEVER deletes anything. For every project reachable
from your gcloud configs it counts what is deletable beyond the keep-count in
each category `cleanup-cloudrun` handles — Cloud Run revisions, App Engine
versions, Artifact Registry image versions, Secret Manager versions — plus
build-scratch buckets missing a lifecycle rule (and the bytes they hold) and
the presence of a legacy GCR
bucket (which usually holds orphaned blobs for `gcr-prune-orphans.py`). Projects
with anything to reclaim are listed first, ranked so the ones carrying real
image storage lead, each with the exact command to run.

Usage:
  ./cleanup-scan.py                     # scan every project across all configs
  ./cleanup-scan.py PROJECT [PROJECT…]  # scan only the named projects
  ./cleanup-scan.py --keep 5 --workers 12
  ./cleanup-scan.py --all               # also list projects that are already clean

Project discovery spans every gcloud config's account (so both gmail- and
uindy-owned projects are covered). Nothing is ever deleted — the tool prints the
`cleanup-cloudrun … --dry-run` command for each project it flags.
"""

import argparse
import concurrent.futures
import json
import subprocess
import sys

KEEP_DEFAULT = 3          # matches cleanup-cloudrun KEEP_COUNT
SECRET_KEEP_DEFAULT = 1   # matches cleanup-cloudrun SECRET_KEEP_COUNT
CALL_TIMEOUT = 90         # seconds per gcloud call

# Build-scratch bucket name patterns cleanup-cloudrun gives a lifecycle rule.
# Kept in sync with trim_build_buckets() in cleanup-cloudrun.sh.
BUILD_BUCKET_SUFFIXES = ("_cloudbuild",)
BUILD_BUCKET_PREFIXES = ("staging.", "gcf-sources-")


# ---------------------------------------------------------------------------
# gcloud plumbing
# ---------------------------------------------------------------------------
def gcloud(args, config, timeout=CALL_TIMEOUT):
    """Run a gcloud command under a specific config. Returns (rc, stdout, stderr).

    stdin is /dev/null so a disabled-API "enable now?" prompt can never hang the
    scan invisibly (the same footgun that bit gcr-prune-orphans). A non-zero rc
    (disabled API, missing resource, no permission) is handled by callers as
    "nothing here", never fatal — one unreachable project must not sink the run.
    """
    env_cmd = ["gcloud", *args]
    try:
        p = subprocess.run(
            env_cmd,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=timeout,
            env=_env(config),
        )
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return 124, "", f"timeout after {timeout}s"


_ENV_CACHE = {}


def _env(config):
    import os
    if config not in _ENV_CACHE:
        e = dict(os.environ)
        e["CLOUDSDK_ACTIVE_CONFIG_NAME"] = config
        # Suppress the interactive component-update nag on stderr.
        e["CLOUDSDK_CORE_DISABLE_PROMPTS"] = "1"
        _ENV_CACHE[config] = e
    return _ENV_CACHE[config]


def gcloud_json(args, config, timeout=CALL_TIMEOUT):
    rc, out, _ = gcloud([*args, "--format=json"], config, timeout)
    if rc != 0 or not out.strip():
        return []
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return []


def human_bytes(n):
    if not n:
        return "0"
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n:.1f}{unit}" if unit != "B" else f"{int(n)}B"
        n /= 1024


# ---------------------------------------------------------------------------
# Discovery: which projects, reachable from which config
# ---------------------------------------------------------------------------
def discover_projects(explicit):
    """Return {project_id: config_name}.

    Project visibility is an identity (account) property, not a config property,
    so we enumerate once per distinct account using a representative config, then
    map each project to that config for the suggested command. If explicit
    project ids were passed we still need a config per project, so we resolve
    each against whichever account can see it.
    """
    rc, out, err = gcloud(["config", "configurations", "list",
                           "--format=value(name,properties.core.account)"], "default")
    if rc != 0:
        sys.exit(f"Could not list gcloud configurations: {err.strip()}")

    account_config = {}   # account -> representative config (first seen)
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) != 2:
            continue
        name, account = parts
        account_config.setdefault(account, name)

    project_config = {}   # project -> config
    for account, config in account_config.items():
        ids = gcloud(["projects", "list", "--filter=lifecycleState:ACTIVE",
                      "--format=value(projectId)"], config)[1]
        for pid in ids.split():
            project_config.setdefault(pid, config)

    if explicit:
        # Keep only requested ids; warn on any we can't reach from any account.
        chosen = {}
        for pid in explicit:
            if pid in project_config:
                chosen[pid] = project_config[pid]
            else:
                print(f"  ! {pid}: not visible from any gcloud config — skipping",
                      file=sys.stderr)
        return chosen

    return project_config


# ---------------------------------------------------------------------------
# Per-category counts (each returns excess-beyond-keep and context)
# ---------------------------------------------------------------------------
def enabled_apis(project, config):
    rc, out, _ = gcloud(["services", "list", "--enabled",
                         f"--project={project}",
                         "--format=value(config.name)"], config)
    if rc != 0:
        return None  # unknown — caller attempts everything
    return set(out.split())


def scan_cloud_run(project, config, keep):
    """Excess Cloud Run revisions = sum over services of max(0, revs - keep)."""
    services = gcloud_json(["run", "services", "list", f"--project={project}"], config)
    if not services:
        return 0, 0
    regions = set()
    for s in services:
        loc = (s.get("metadata", {}).get("labels", {}) or {}).get(
            "cloud.googleapis.com/location")
        if loc:
            regions.add(loc)
    per_service = {}
    for region in regions:
        revs = gcloud_json(["run", "revisions", "list", f"--region={region}",
                            f"--project={project}"], config)
        for r in revs:
            svc = (r.get("metadata", {}).get("labels", {}) or {}).get(
                "serving.knative.dev/service", "?")
            per_service[svc] = per_service.get(svc, 0) + 1
    excess = sum(max(0, c - keep) for c in per_service.values())
    return excess, len(services)


def scan_app_engine(project, config, keep):
    """Excess App Engine versions, never counting a version serving traffic."""
    rc, out, _ = gcloud(["app", "versions", "list", f"--project={project}",
                         "--sort-by=service,~version.createTime",
                         "--format=value(service,id,traffic_split)"], config)
    if rc != 0 or not out.strip():
        return 0, 0
    prev, count, excess, total = None, 0, 0, 0
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        svc, _id, split = parts[0], parts[1], parts[2]
        total += 1
        if svc != prev:
            prev, count = svc, 0
        count += 1
        try:
            serving = float(split) > 0
        except ValueError:
            serving = False
        if count > keep and not serving:
            excess += 1
    return excess, total


def scan_artifact_registry(project, config, keep):
    """Excess AR image versions + total AR footprint bytes across docker repos."""
    repos = gcloud_json(["artifacts", "repositories", "list",
                         f"--project={project}"], config)
    excess, footprint = 0, 0
    for r in repos:
        parts = r.get("name", "").split("/")
        if len(parts) < 6:
            continue
        location, repo_id = parts[3], parts[5]
        if repo_id.endswith(".gcr.io") or repo_id == "gcr.io":
            continue  # legacy GCR bridge — counted separately
        footprint += int(r.get("sizeBytes", 0) or 0)
        if (r.get("format", "") or "").upper() != "DOCKER":
            continue
        base = f"{location}-docker.pkg.dev/{project}/{repo_id}"
        imgs = gcloud_json(["artifacts", "docker", "images", "list", base,
                            f"--project={project}"], config)
        per_pkg = {}
        for i in imgs:
            pkg = i.get("package")
            if pkg:
                per_pkg[pkg] = per_pkg.get(pkg, 0) + 1
        excess += sum(max(0, c - keep) for c in per_pkg.values())
    return excess, footprint


def scan_legacy_gcr(project, config):
    """True if a legacy us.artifacts.<project>.appspot.com bucket holds objects.

    A non-recursive top-level listing is one API page — fast even on a huge
    bucket — and distinguishes a bucket with content from an empty (or absent)
    one, so a freshly-pruned bucket that still exists isn't re-flagged. Exact
    reclaimable bytes are left to gcr-prune-orphans.py's dry run.
    """
    rc, out, _ = gcloud(["storage", "ls", f"gs://us.artifacts.{project}.appspot.com",
                         f"--project={project}"], config, timeout=30)
    return rc == 0 and bool(out.strip())


def scan_secrets(project, config, secret_keep):
    """Excess active (enabled+disabled) Secret Manager versions beyond keep."""
    rc, out, _ = gcloud(["secrets", "list", f"--project={project}",
                         "--format=value(name)"], config)
    if rc != 0 or not out.strip():
        return 0, 0
    names = [n for n in out.split() if n]
    excess = 0
    for name in names:
        vers = gcloud(["secrets", "versions", "list", name,
                       f"--project={project}",
                       "--filter=state=ENABLED OR state=DISABLED",
                       "--format=value(name)"], config)[1]
        count = len([v for v in vers.split() if v])
        excess += max(0, count - secret_keep)
    return excess, len(names)


def bucket_bytes(bucket, project, config):
    """Total bytes in a bucket, or 0 if it cannot be sized.

    `du -s` walks every object, so this is called only on the handful of
    build-scratch buckets already known to lack a lifecycle rule — never on the
    whole bucket list. A timeout or error degrades to 0: an unsized bucket is
    still reported as missing its rule, just without bytes behind it.
    """
    rc, out, _ = gcloud(["storage", "du", "-s", f"gs://{bucket}",
                         f"--project={project}"], config)
    if rc != 0:
        return 0
    # Output is "<bytes>  gs://<bucket>".
    try:
        return int(out.split()[0])
    except (IndexError, ValueError):
        return 0


def scan_build_buckets(project, config):
    """Count build-scratch buckets lacking a lifecycle rule, and size them.

    The bytes are what setting the rule would eventually reclaim. They can dwarf
    a project's entire AR footprint — an un-swept `_cloudbuild` bucket grows by
    one source tarball per build, forever — so they feed the ranking score
    rather than being reported as a bare bucket count.
    """
    rc, out, _ = gcloud(["storage", "buckets", "list", f"--project={project}",
                         "--format=value(name)"], config)
    if rc != 0 or not out.strip():
        return 0, 0
    missing, total = 0, 0
    for bucket in out.split():
        is_build = (bucket.endswith(BUILD_BUCKET_SUFFIXES)
                    or bucket.startswith(BUILD_BUCKET_PREFIXES))
        if not is_build:
            continue
        rule = gcloud(["storage", "buckets", "describe", f"gs://{bucket}",
                       f"--project={project}",
                       "--format=value(lifecycle_config.rule)"], config,
                      timeout=30)[1]
        if not rule.strip():
            missing += 1
            total += bucket_bytes(bucket, project, config)
    return missing, total


# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------
def scan_project(project, config, keep, secret_keep):
    apis = enabled_apis(project, config)

    def on(api):
        return apis is None or api in apis

    f = {"project": project, "config": config}
    f["run_excess"], f["run_services"] = (
        scan_cloud_run(project, config, keep) if on("run.googleapis.com") else (0, 0))
    f["ae_excess"], f["ae_versions"] = (
        scan_app_engine(project, config, keep) if on("appengine.googleapis.com") else (0, 0))
    f["ar_excess"], f["ar_bytes"] = (
        scan_artifact_registry(project, config, keep)
        if on("artifactregistry.googleapis.com") else (0, 0))
    f["secret_excess"], f["secrets"] = (
        scan_secrets(project, config, secret_keep)
        if on("secretmanager.googleapis.com") else (0, 0))
    # Cloud Storage is effectively always-on and frequently absent from the
    # enabled-APIs list even where buckets exist and are describable, so the
    # bucket checks run unconditionally (the calls fail cleanly if truly absent).
    f["gcr_bucket"] = scan_legacy_gcr(project, config)
    f["buckets_no_lifecycle"], f["bucket_bytes"] = scan_build_buckets(project, config)

    f["excess_total"] = (f["run_excess"] + f["ae_excess"] + f["ar_excess"]
                         + f["secret_excess"] + f["buckets_no_lifecycle"])
    f["ready"] = f["excess_total"] > 0 or f["gcr_bucket"]
    # Rank: reclaimable storage first, then legacy-GCR presence, then raw
    # excess-item count. Build-scratch bytes join the AR footprint in that first
    # term because a single un-swept _cloudbuild bucket can outweigh every image
    # in the project — ranking on AR alone buried a 27GB bucket near the bottom.
    f["score"] = (f["ar_bytes"] + f["bucket_bytes"],
                  1 if f["gcr_bucket"] else 0,
                  f["excess_total"])
    return f


def reason(f):
    bits = []
    if f["ar_excess"]:
        bits.append(f"{f['ar_excess']} excess AR images")
    if f["ar_bytes"]:
        bits.append(f"{human_bytes(f['ar_bytes'])} AR footprint")
    if f["gcr_bucket"]:
        bits.append("legacy GCR bucket (→ gcr-prune-orphans)")
    if f["ae_excess"]:
        bits.append(f"{f['ae_excess']} excess App Engine versions")
    if f["run_excess"]:
        bits.append(f"{f['run_excess']} excess Cloud Run revisions")
    if f["secret_excess"]:
        bits.append(f"{f['secret_excess']} excess secret versions")
    if f["buckets_no_lifecycle"]:
        size = f" ({human_bytes(f['bucket_bytes'])})" if f["bucket_bytes"] else ""
        bits.append(f"{f['buckets_no_lifecycle']} build bucket(s) w/o lifecycle{size}")
    return ", ".join(bits) if bits else "nothing to reclaim"


def main():
    ap = argparse.ArgumentParser(
        description="Triage which GCP projects would repay a cleanup-cloudrun run (read-only).")
    ap.add_argument("projects", nargs="*", help="specific project ids (default: all)")
    ap.add_argument("--keep", type=int, default=KEEP_DEFAULT,
                    help=f"revisions/versions/images to keep (default {KEEP_DEFAULT})")
    ap.add_argument("--secret-keep", type=int, default=SECRET_KEEP_DEFAULT,
                    help=f"secret versions to keep (default {SECRET_KEEP_DEFAULT})")
    ap.add_argument("--workers", type=int, default=8, help="parallel projects (default 8)")
    ap.add_argument("--all", action="store_true", help="also list already-clean projects")
    args = ap.parse_args()

    print("Discovering projects across all gcloud configs…", file=sys.stderr)
    projects = discover_projects(args.projects)
    if not projects:
        sys.exit("No projects to scan.")
    print(f"Scanning {len(projects)} project(s) with {args.workers} workers "
          f"(keep={args.keep}, secret-keep={args.secret_keep})…\n", file=sys.stderr)

    findings = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as ex:
        futs = {ex.submit(scan_project, p, c, args.keep, args.secret_keep): p
                for p, c in sorted(projects.items())}
        done = 0
        for fut in concurrent.futures.as_completed(futs):
            done += 1
            p = futs[fut]
            try:
                findings.append(fut.result())
            except Exception as e:  # noqa: BLE001 — never let one project sink the run
                print(f"  ! {p}: scan error: {e}", file=sys.stderr)
            print(f"\r  scanned {done}/{len(projects)}", end="", file=sys.stderr, flush=True)
    print("\n", file=sys.stderr)

    ready = sorted([f for f in findings if f["ready"]], key=lambda f: f["score"], reverse=True)
    clean = [f for f in findings if not f["ready"]]

    if ready:
        print("━━━ Projects ready for cleanup ━━━\n")
        width = max(len(f["project"]) for f in ready)
        for f in ready:
            print(f"  {f['project']:<{width}}  {reason(f)}")
        print("\n  Run (dry-run first):")
        for f in ready:
            print(f"    CLOUDSDK_ACTIVE_CONFIG_NAME={f['config']} "
                  f"cleanup-cloudrun {f['project']} --dry-run")
    else:
        print("No projects have anything to reclaim. Fleet is clean. ✓")

    if args.all and clean:
        print(f"\n━━━ Already clean ({len(clean)}) ━━━")
        print("  " + ", ".join(sorted(f["project"] for f in clean)))

    print(f"\nScanned {len(findings)} project(s): "
          f"{len(ready)} ready, {len(clean)} clean.", file=sys.stderr)


if __name__ == "__main__":
    main()
