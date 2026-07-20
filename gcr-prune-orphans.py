#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gcr-prune-orphans.py

Finds and optionally deletes orphaned layer blobs from the legacy GCR GCS
bucket (us.artifacts.PROJECT.appspot.com).

GCR garbage collection runs unreliably; this does the job manually.
A blob is "orphaned" if it exists in the bucket but is not referenced by
any layer or config in any active Cloud Run revision manifest.

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
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print('ERROR: Not authenticated. Run: gcloud auth application-default login',
              file=sys.stderr)
        sys.exit(1)
    return result.stdout.strip()


def gcloud_json(args):
    result = subprocess.run(
        ['gcloud'] + args + ['--format=json'],
        capture_output=True, text=True
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
def collect_blobs(token, registry, repo, manifest, blobs, errors, depth=0):
    if depth > 3:
        return
    if 'manifests' in manifest:
        # Manifest list / OCI index — recurse into each platform manifest
        for m in manifest['manifests']:
            blobs.add(m['digest'])
            try:
                child = fetch_manifest(token, registry, repo, m['digest'])
                collect_blobs(token, registry, repo, child, blobs, errors, depth + 1)
            except Exception as e:
                errors.append(f"child {m['digest'][:19]}: {e}")
    else:
        if 'config' in manifest:
            blobs.add(manifest['config']['digest'])
        for layer in manifest.get('layers', []):
            blobs.add(layer['digest'])


def get_referenced_blobs(token, images):
    blobs  = set()
    errors = []
    for img in images:
        registry        = img.split('/')[0]
        rest            = '/'.join(img.split('/')[1:])
        repo, ref       = (rest.rsplit('@', 1) if '@' in rest else rest.rsplit(':', 1))
        try:
            manifest = fetch_manifest(token, registry, repo, ref)
            collect_blobs(token, registry, repo, manifest, blobs, errors)
        except Exception as e:
            errors.append(f'{img}: {e}')
    return blobs, errors


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
    args = parser.parse_args()

    project = args.project
    bucket  = f'us.artifacts.{project}.appspot.com'

    hdr(f'GCR Orphan Analysis: {project}')
    if args.delete:
        print(f'  {RED}{BOLD}DELETE MODE — orphaned blobs will be removed{NC}')
    else:
        print(f'  {DIM}Dry run — pass --delete to remove orphaned blobs{NC}')

    token = get_token()

    # ── Collect active images from all Cloud Run revisions ────────────────────
    print()
    info('Collecting active Cloud Run revision images...')

    services = gcloud_json(['run', 'services', 'list', f'--project={project}'])
    all_images = set()

    for svc in services:
        name   = svc['metadata']['name']
        region = svc['metadata'].get('labels', {}).get(
            'cloud.googleapis.com/location', 'us-central1')
        revisions = gcloud_json([
            'run', 'revisions', 'list',
            f'--service={name}',
            f'--region={region}',
            f'--project={project}',
        ])
        for rev in revisions:
            img = rev['spec']['containers'][0]['image']
            all_images.add(img)

    if not all_images:
        print('  ERROR: No images found — aborting to be safe.', file=sys.stderr)
        sys.exit(1)

    info(f'Found {len(all_images)} unique images across active revisions')

    # ── Fetch manifests; collect referenced blobs ─────────────────────────────
    info('Fetching manifests...')
    referenced, errors = get_referenced_blobs(token, all_images)

    for e in errors:
        print(f'  {YELLOW}WARNING: {e}{NC}', file=sys.stderr)

    info(f'Referenced blobs across all manifests: {len(referenced)}')

    if not referenced:
        print('  ERROR: Zero referenced blobs — manifest fetch failed, aborting.',
              file=sys.stderr)
        sys.exit(1)

    # ── List bucket; compare ──────────────────────────────────────────────────
    info(f'Listing gs://{bucket}/containers/images/ ...')
    all_objects = list_bucket_objects(token, project, bucket)

    if all_objects is None:
        info(f'Bucket gs://{bucket} not found — no legacy GCR storage for this project.')
        sys.exit(0)

    orphaned = {d: s for d, s in all_objects.items() if d not in referenced}
    kept     = {d: s for d, s in all_objects.items() if d in referenced}

    orphan_bytes = sum(orphaned.values())
    kept_bytes   = sum(kept.values())
    orphan_cost  = orphan_bytes / (1 << 30) * 0.026

    # ── Report ────────────────────────────────────────────────────────────────
    hdr(f'Results: {project}')
    print(f'  {"Referenced (keep):":<30}  {len(kept):5d}  {human(kept_bytes):>10}')
    print(f'  {"Orphaned (safe to delete):":<30}  {len(orphaned):5d}  '
          f'{human(orphan_bytes):>10}  ~${orphan_cost:.4f}/mo')
    print(f'  {"Total objects in bucket:":<30}  {len(all_objects):5d}')
    print()
    note(f'Bucket: gs://{bucket}/containers/images/')
    note('Rate: GCS Standard $0.026/GB/mo')

    if not orphaned:
        print(f'\n  {GREEN}✓ No orphaned blobs — bucket is clean.{NC}')
        return

    if not args.delete:
        print(f'\n  {YELLOW}Dry run. Re-run with --delete to remove '
              f'{len(orphaned)} orphaned blobs.{NC}')
        return

    # ── Delete ────────────────────────────────────────────────────────────────
    print(f'\n  Deleting {len(orphaned)} orphaned blobs...')

    to_delete = [
        f'gs://{bucket}/containers/images/{d}' for d in sorted(orphaned)
    ]
    proc = subprocess.run(
        ['gsutil', '-m', 'rm', '-I'],
        input='\n'.join(to_delete),
        text=True, capture_output=True,
    )
    # gsutil -m rm prints progress to stderr
    for line in proc.stderr.splitlines()[-5:]:
        print(f'  {line}')

    if proc.returncode == 0:
        print(f'\n  {GREEN}✓ Deleted {len(orphaned)} blobs.{NC}')
    else:
        print(f'\n  {YELLOW}⚠ gsutil exited {proc.returncode} '
              f'(some objects may already be gone).{NC}')
    note("Re-run without --delete to verify the bucket is clean.")


if __name__ == '__main__':
    main()
