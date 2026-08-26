#!/usr/bin/env -S uv run --script
# -*- coding: utf-8 -*-
# /// script
# requires-python = ">=3.8"
# dependencies = []
# ///
"""
gcr-prune-orphans.py

Finds and optionally deletes orphaned layer blobs from the legacy GCR GCS
bucket (us.artifacts.PROJECT.appspot.com).

GCR garbage collection runs unreliably; this does the job manually.
A blob is "orphaned" if it exists in the bucket but is not referenced by
any manifest that STILL EXISTS in the registry — where the keep-set is built
from both active Cloud Run revisions AND every manifest across the whole
us.gcr.io/PROJECT tree (recursively). App Engine *standard* projects serve
from staged source, not these images, so their build-scratch blobs are
reclaimable; App Engine flexible / base images stay tagged and are kept.

Safety: the tool REFUSES to --delete if registry enumeration or any manifest
read failed (an incomplete keep-set could mislabel a live blob as orphaned),
and requires typed confirmation before a total wipe of a project whose
registry references nothing.

Usage:
    ./gcr-prune-orphans.py <project-id> [--delete]

Dry-run by default. Only touches objects under containers/images/.
"""

import json
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import argparse


# ── Colours ───────────────────────────────────────────────────────────────────
BOLD   = '\033[1m'
DIM    = '\033[2m'
GREEN  = '\033[0;32m'
YELLOW = '\033[1;33m'
RED    = '\033[0;31m'
NC     = '\033[0m'

def hdr(msg):   print(f'\n{BOLD}━━━ {msg} ━━━{NC}')
def note(msg):  print(f'    {DIM}{msg}{NC}')
def info(msg):  print(f'  {msg}')


def human(b):
    if b >= 1 << 30: return f'{b / (1 << 30):.2f} GB'
    if b >= 1 << 20: return f'{b / (1 << 20):.2f} MB'
    if b >= 1 << 10: return f'{b / (1 << 10):.2f} KB'
    return f'{b} B'


# ── GCP helpers ───────────────────────────────────────────────────────────────
def get_token():
    result = subprocess.run(
        ['gcloud', 'auth', 'print-access-token'],
        capture_output=True, text=True, stdin=subprocess.DEVNULL
    )
    if result.returncode != 0:
        print('ERROR: Not authenticated. Run: gcloud auth application-default login',
              file=sys.stderr)
        sys.exit(1)
    return result.stdout.strip()


def gcloud_json(args):
    # stdin=DEVNULL so a disabled-API "enable and retry? (y/N)" prompt (which
    # gcloud writes to the captured stderr, invisibly) gets EOF and defaults to
    # No instead of blocking the whole tool on a hidden prompt.
    result = subprocess.run(
        ['gcloud'] + args + ['--format=json'],
        capture_output=True, text=True, stdin=subprocess.DEVNULL
    )
    if result.returncode != 0:
        return []
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return []


def gcs_get(token, project, bucket, path, params=None):
    url = f'https://storage.googleapis.com/storage/v1/b/{bucket}/{path}'
    if params:
        url += '?' + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={
        'Authorization':       f'Bearer {token}',
        'x-goog-user-project': project,
    })
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())


def fetch_manifest(token, registry, repo, ref):
    url = f'https://{registry}/v2/{repo}/manifests/{ref}'
    req = urllib.request.Request(url, headers={
        'Authorization': f'Bearer {token}',
        'Accept': ', '.join([
            'application/vnd.docker.distribution.manifest.v2+json',
            'application/vnd.oci.image.manifest.v1+json',
            'application/vnd.docker.distribution.manifest.list.v2+json',
            'application/vnd.oci.image.index.v1+json',
        ]),
    })
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read())


# ── Blob collection ───────────────────────────────────────────────────────────
def collect_blobs(token, registry, repo, manifest, blobs, manifests, errors, depth=0):
    """Populate two sets from a manifest:
      blobs     — config + layer digests. These are the objects physically
                  stored under containers/images/ and are what the integrity
                  check requires to be present.
      manifests — child-manifest digests of a manifest list / OCI index. GCR
                  keeps manifest objects in registry metadata, NOT necessarily
                  under containers/images/, so they must be kept from deletion
                  but must NOT be asserted as bucket blobs (that would false-
                  alarm the integrity check)."""
    if depth > 3:
        return
    if 'manifests' in manifest:
        # Manifest list / OCI index — recurse into each platform manifest
        for m in manifest['manifests']:
            manifests.add(m['digest'])
            try:
                child = fetch_manifest(token, registry, repo, m['digest'])
                collect_blobs(token, registry, repo, child,
                              blobs, manifests, errors, depth + 1)
            except Exception as e:
                errors.append(f"child {m['digest'][:19]}: {e}")
    else:
        if 'config' in manifest:
            blobs.add(manifest['config']['digest'])
        for layer in manifest.get('layers', []):
            blobs.add(layer['digest'])


def get_referenced_blobs(token, images):
    """Returns (blobs, manifests, errors):
      blobs     — config + layer digests that MUST exist under containers/images/
      manifests — manifest-object digests (self + manifest-list children); kept
                  from deletion but not required to be bucket blobs."""
    blobs       = set()
    manifests   = set()
    image_blobs = {}      # image_ref -> set of its own config/layer digests
    errors      = []
    for img in images:
        registry        = img.split('/')[0]
        rest            = '/'.join(img.split('/')[1:])
        repo, ref       = (rest.rsplit('@', 1) if '@' in rest else rest.rsplit(':', 1))
        try:
            manifest = fetch_manifest(token, registry, repo, ref)
            # Keep the manifest's own object from deletion (it may or may not sit
            # under containers/images/); tracked separately from blobs so it is
            # never asserted as a required bucket object.
            if ref.startswith('sha256:'):
                manifests.add(ref)
            b = set()
            collect_blobs(token, registry, repo, manifest, b, manifests, errors)
            image_blobs[img] = b
            blobs |= b
        except Exception as e:
            errors.append(f'{img}: {e}')
    return blobs, manifests, image_blobs, errors


def registry_tags_list(token, registry, repo):
    """GCR's /v2/<repo>/tags/list. GCR extends the Docker spec: the response
    carries `manifest` (a dict keyed by FULL sha256 digest — tagged AND
    untagged) and `child` (immediate sub-repositories). Unlike
    `gcloud container images list-tags --format=value(digest)`, which returns
    truncated 12-char digests unusable for a manifest fetch, this gives the
    full digests the bucket object names are keyed by."""
    url = f'https://{registry}/v2/{repo}/tags/list'
    req = urllib.request.Request(url, headers={'Authorization': f'Bearer {token}'})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())


def enumerate_registry_images(token, registry, repo, depth=0, errors=None):
    """Recursively list EVERY manifest currently in a gcr.io repository tree,
    returned as 'registry/path@sha256:<full>' refs.

    This is the fix for the Cloud-Run-only keep-set: the true orphan test is
    "referenced by NO manifest that still exists", so the keep-set must come
    from the whole registry (App Engine build images, base images, anything
    tagged), not just Cloud Run revisions. GCR nests arbitrarily deep
    (app-engine-tmp/app/default/ttl-18h), so this recurses. Returns
    (image_refs, ok); ok is False if any node failed to list, so the caller can
    refuse to --delete on an incomplete keep-set."""
    if errors is None:
        errors = []
    imgs = []
    ok = True
    if depth > 8:  # runaway guard; real nesting tops out ~4
        errors.append(f'max depth at {repo}')
        return imgs, False

    try:
        data = registry_tags_list(token, registry, repo)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return imgs, True  # empty node — normal, not a failure
        errors.append(f'tags/list {repo}: {e}')
        return imgs, False
    except Exception as e:
        errors.append(f'tags/list {repo}: {e}')
        return imgs, False

    for digest in (data.get('manifest') or {}):
        imgs.append(f'{registry}/{repo}@{digest}')
    for child in (data.get('child') or []):
        c_imgs, c_ok = enumerate_registry_images(
            token, registry, f'{repo}/{child}', depth + 1, errors)
        imgs.extend(c_imgs)
        ok = ok and c_ok

    return imgs, ok


# ── GCS bucket listing ────────────────────────────────────────────────────────
def list_bucket_objects(token, project, bucket, prefix='containers/images/'):
    objects    = {}
    page_token = ''
    while True:
        params = {
            'fields':     'nextPageToken,items(name,size)',
            'maxResults': '1000',
            'prefix':     prefix,
        }
        if page_token:
            params['pageToken'] = page_token
        try:
            d = gcs_get(token, project, bucket, 'o', params)
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None  # bucket doesn't exist
            raise
        for item in d.get('items', []):
            digest = item['name'].split('/')[-1]
            objects[digest] = int(item.get('size', 0))
        page_token = d.get('nextPageToken', '')
        if not page_token:
            break
    return objects


# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(
        description='Find and optionally delete orphaned GCR blobs.')
    parser.add_argument('project', help='GCP project ID')
    parser.add_argument('--delete', action='store_true',
                        help='Actually delete orphaned blobs (default: dry run)')
    parser.add_argument('--dry-run', action='store_true',
                        help='Explicitly force a dry run. This is already the '
                             'default; if both --dry-run and --delete are given, '
                             '--dry-run wins (fail-safe).')
    args = parser.parse_args()

    # Dry run is the default and always wins a tie: only an explicit --delete
    # WITHOUT --dry-run performs deletion.
    do_delete = args.delete and not args.dry_run

    project = args.project
    bucket  = f'us.artifacts.{project}.appspot.com'

    hdr(f'GCR Orphan Analysis: {project}')
    if do_delete:
        print(f'  {RED}{BOLD}DELETE MODE — orphaned blobs will be removed{NC}')
    else:
        print(f'  {DIM}Dry run — pass --delete to remove orphaned blobs{NC}')

    token = get_token()

    # ── Build the keep-set from EVERY manifest that still exists ──────────────
    # Two sources, unioned:
    #   1. Active Cloud Run revision images (runtime-pulled; must survive).
    #   2. Every manifest in the us.gcr.io/PROJECT registry tree (App Engine
    #      build images, base images, anything tagged).
    # This is what makes the orphan test correct: a blob is orphaned only if NO
    # surviving manifest references it. The old keep-set was Cloud-Run-only,
    # which on an App Engine / mixed project would flag live images as orphaned.
    print()
    info('Collecting active Cloud Run revision images...')
    services = gcloud_json(['run', 'services', 'list', f'--project={project}'])
    cloud_run_images = set()
    for svc in services:
        name   = svc['metadata']['name']
        region = svc['metadata'].get('labels', {}).get(
            'cloud.googleapis.com/location', 'us-central1')
        revisions = gcloud_json([
            'run', 'revisions', 'list',
            f'--service={name}', f'--region={region}', f'--project={project}',
        ])
        for rev in revisions:
            cloud_run_images.add(rev['spec']['containers'][0]['image'])
    info(f'  {len(cloud_run_images)} unique Cloud Run revision image(s)')

    info(f'Enumerating every manifest in us.gcr.io/{project} (recursive)...')
    enum_errors = []
    registry_images, enum_ok = enumerate_registry_images(
        token, 'us.gcr.io', project, errors=enum_errors)
    info(f'  {len(registry_images)} manifest(s) across the registry tree'
         + ('' if enum_ok else f'  {YELLOW}(enumeration INCOMPLETE){NC}'))

    all_images = cloud_run_images | set(registry_images)

    # ── Fetch manifests; collect referenced blobs ─────────────────────────────
    info('Fetching manifests to collect referenced blobs...')
    referenced_blobs, referenced_manifests, image_blobs, fetch_errors = \
        get_referenced_blobs(token, all_images)
    referenced = referenced_blobs | referenced_manifests   # full keep-set
    for e in enum_errors + fetch_errors:
        print(f'  {YELLOW}WARNING: {e}{NC}', file=sys.stderr)
    info(f'Referenced: {len(referenced_blobs)} config/layer blob(s) '
         f'+ {len(referenced_manifests)} manifest object(s)')

    # A blank keep-set may only drive a delete when it is PROVABLY blank: the
    # registry genuinely holds no manifests and enumeration was clean. If images
    # existed but produced no blobs, that is a read failure, not an empty repo.
    keepset_complete = enum_ok and not fetch_errors
    if all_images and not referenced:
        print('  ERROR: manifests were found but yielded zero referenced blobs '
              '— treating as a read failure, aborting.', file=sys.stderr)
        sys.exit(1)

    # ── List bucket; compare ──────────────────────────────────────────────────
    info(f'Listing gs://{bucket}/containers/images/ ...')
    all_objects = list_bucket_objects(token, project, bucket)

    if all_objects is None:
        info(f'Bucket gs://{bucket} not found — no legacy GCR storage for this project.')
        sys.exit(0)

    bucket_keys = set(all_objects.keys())
    orphaned = {d: s for d, s in all_objects.items() if d not in referenced}
    kept     = {d: s for d, s in all_objects.items() if d in referenced}

    # ── Integrity invariant ───────────────────────────────────────────────────
    # For every image RESIDENT IN THIS BUCKET, all its config/layer blobs must be
    # present, or the image is broken. `missing` must be empty. Run before AND
    # after a prune: before certifies the store is healthy; after certifies the
    # prune removed only true orphans and every needed blob survived.
    #
    # Residency matters because Google migrated gcr.io onto the Artifact Registry
    # backend: on a migrated/mixed project the LIVE images keep their blobs in AR,
    # not in this legacy GCS bucket, so requiring them here would false-alarm (and
    # they can never be in the delete set anyway — their blobs aren't in-bucket).
    # An image is "resident" if any of its blobs are in the bucket; then ALL of
    # them must be. Manifest objects are excluded (registry metadata, not blobs).
    missing = set()
    resident_images = 0
    for img, b in image_blobs.items():
        if b & bucket_keys:            # at least one blob here -> legacy-resident
            resident_images += 1
            missing |= (b - bucket_keys)
    integrity_ok = not missing

    orphan_bytes = sum(orphaned.values())
    kept_bytes   = sum(kept.values())
    orphan_cost  = orphan_bytes / (1 << 30) * 0.026

    # ── Report ────────────────────────────────────────────────────────────────
    hdr(f'Results: {project}')
    print(f'  {"Referenced (keep):":<30}  {len(kept):5d}  {human(kept_bytes):>10}')
    print(f'  {"Orphaned (safe to delete):":<30}  {len(orphaned):5d}  '
          f'{human(orphan_bytes):>10}  ~${orphan_cost:.4f}/mo')
    print(f'  {"Total objects in bucket:":<30}  {len(all_objects):5d}')
    if integrity_ok:
        print(f'  {GREEN}Integrity — {resident_images} in-bucket image(s): '
              f'all layers present ✓{NC}')
    else:
        print(f'  {RED}{BOLD}Integrity — layer blobs MISSING:  {len(missing):5d}  '
              f'(across {resident_images} in-bucket image(s)) '
              f'← an image is broken; do NOT prune, investigate{NC}')
    print()
    note(f'Bucket: gs://{bucket}/containers/images/')
    note('Rate: GCS Standard $0.026/GB/mo')

    if not orphaned:
        print(f'\n  {GREEN}✓ No orphaned blobs — bucket is clean.{NC}')
        return

    if not do_delete:
        print(f'\n  {YELLOW}Dry run. Re-run with --delete to remove '
              f'{len(orphaned)} orphaned blobs.{NC}')
        return

    # ── Safety gates before any deletion ──────────────────────────────────────
    # Never delete against an incomplete keep-set: a failed enumeration or a
    # failed manifest read could hide a live reference, turning a kept blob into
    # a false orphan.
    if not keepset_complete:
        print(f'\n  {RED}REFUSING to delete: the keep-set is incomplete '
              f'(registry enumeration or a manifest read failed above). '
              f'Fix the errors and re-run — dry-run stays available.{NC}',
              file=sys.stderr)
        sys.exit(1)
    if not integrity_ok:
        print(f'\n  {RED}REFUSING to delete: {len(missing)} referenced blob(s) '
              f'are already missing from the bucket — the store is inconsistent. '
              f'Investigate the broken image before pruning.{NC}', file=sys.stderr)
        sys.exit(1)
    # An empty keep-set means nothing in the registry references anything: every
    # blob is unreferenced scratch. That is legitimate (e.g. an App Engine
    # project whose gcr repo is gone) but total, so make the operator confirm.
    if not referenced:
        print(f'\n  {YELLOW}The keep-set is EMPTY — no surviving manifest '
              f'references any blob, so ALL {len(orphaned)} objects '
              f'({human(orphan_bytes)}) will be deleted.{NC}')
        resp = input('  Type the project id to confirm total wipe: ').strip()
        if resp != project:
            print('  Aborted.', file=sys.stderr)
            sys.exit(1)

    # ── Delete ────────────────────────────────────────────────────────────────
    print(f'\n  Deleting {len(orphaned)} orphaned blobs...')

    to_delete = [
        f'gs://{bucket}/containers/images/{d}' for d in sorted(orphaned)
    ]
    proc = subprocess.run(
        ['gcloud', 'storage', 'rm', '-I'],
        input='\n'.join(to_delete),
        text=True, capture_output=True,
    )
    # gcloud storage rm prints progress to stderr
    for line in proc.stderr.splitlines()[-5:]:
        print(f'  {line}')

    if proc.returncode == 0:
        print(f'\n  {GREEN}✓ Deleted {len(orphaned)} blobs.{NC}')
    else:
        print(f'\n  {YELLOW}⚠ gcloud storage exited {proc.returncode} '
              f'(some objects may already be gone).{NC}')
    note("Re-run without --delete to verify the bucket is clean.")


if __name__ == '__main__':
    main()
