"""Report status codes for the protected release credential using GET only."""

import argparse
import json
import os
import re
import subprocess

import common


def probe(label, endpoint):
    try:
        result = subprocess.run(
            ['gh', 'api', '--method', 'GET', '--include', endpoint],
            capture_output=True, text=True, timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired):
        print(f'{label}: no HTTP response', flush=True)
        return None, None
    first_line = result.stdout.partition('\n')[0].rstrip('\r')
    response = re.match(r'^HTTP/\S+ ([1-5][0-9]{2})(?:[ \t]|$)', first_line)
    if response is None:
        print(f'{label}: no HTTP response', flush=True)
        return None, None
    status = int(response[1])
    print(f'{label}: HTTP {status}', flush=True)
    if status == 404:
        legacy = '(HTTP 404)' in result.stderr
        print(f'{label}: legacy 404 marker present: {str(legacy).lower()}', flush=True)
    if status != 200 or result.returncode:
        return status, None
    parts = result.stdout.replace('\r\n', '\n').split('\n\n', 1)
    try:
        return status, json.loads(parts[1])
    except (IndexError, ValueError):
        print(f'{label}: invalid JSON response', flush=True)
        return status, None


def diagnose(version, release_id):
    token = os.environ.get('GH_TOKEN')
    if not token:
        raise SystemExit('Protected release credential is missing')
    if any(char.isspace() for char in token):
        raise SystemExit('Protected release credential contains whitespace')
    expected = common.selected(version)
    if not re.fullmatch(r'[1-9][0-9]*', release_id):
        raise SystemExit('Invalid release identity')
    repo = f'repos/{common.REPO}'
    tag = 'desktop-v'+version

    def matching_draft(value):
        return (
            isinstance(value, dict) and str(value.get('id')) == release_id
            and value.get('tag_name') == tag
            and value.get('target_commitish') == expected['sourceRevision']
            and value.get('draft') is True
            and value.get('prerelease') is (expected['channel'] == 'beta')
        )

    # Installation tokens cannot use the authenticated-user endpoint. The
    # repository and exact draft tests decide whether this credential can read.
    probe('Credential identity (advisory)', 'user')
    repo_status, repository = probe('Repository', repo)
    tag_status, tagged = probe('Release by tag', f'{repo}/releases/tags/{tag}')
    _, direct = probe('Release by ID', f'{repo}/releases/{release_id}')
    direct_matches = matching_draft(direct)
    print(f'Release by ID matches expected draft: {str(direct_matches).lower()}', flush=True)
    if repo_status != 200 or not isinstance(repository, dict):
        raise SystemExit('Credential or repository access check failed')
    if tag_status == 200 and matching_draft(tagged) and direct_matches:
        return
    if tag_status != 404:
        raise SystemExit('Release tag lookup failed')
    for page in range(1, 21):
        _, rows = probe('Release listing', f'{repo}/releases?per_page=100&page={page}')
        if not isinstance(rows, list):
            raise SystemExit('Release listing did not return a valid page')
        matches = [row for row in rows if isinstance(row, dict) and row.get('tag_name') == tag]
        if matches:
            if len(matches) != 1 or not matching_draft(matches[0]) or not direct_matches:
                raise SystemExit('Release listing and direct lookup disagree on draft identity')
            print('Release listing found the expected unpublished draft', flush=True)
            return
        if len(rows) < 100:
            break
    raise SystemExit('Expected draft is not visible within the bounded listing')


if __name__ == '__main__':
    args = argparse.ArgumentParser()
    args.add_argument('version')
    args.add_argument('release_id')
    options = args.parse_args()
    diagnose(options.version, options.release_id)
