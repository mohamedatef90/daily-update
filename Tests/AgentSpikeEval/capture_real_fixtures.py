#!/usr/bin/env python3 -I
"""Builds the REAL fixtures of the AI spike eval from this Mac's `--discover --json` and `--check --json`
output. Home paths and the account name are replaced with `~` / `<user>` before anything is written.
Usage: capture_real_fixtures.py <discover.json> <check.json> <out-dir>"""
import json, os, re, sys

discover = json.load(open(sys.argv[1]))
check = {i['id']: i for i in json.load(open(sys.argv[2]))}
out = sys.argv[3]
home = os.path.expanduser('~')
user = os.path.basename(home)

def redact(value):
    if isinstance(value, str):
        value = value.replace(home, '~')
        value = re.sub(r'/Users/[^/\s"\'\\]+', '~', value)
        return re.sub(re.escape(user), '<user>', value, flags=re.I)
    if isinstance(value, list):
        return [redact(v) for v in value]
    if isinstance(value, dict):
        return {k: redact(v) for k, v in value.items()}
    return value

rows = {r['id']: r for r in discover['rows']}
# (fixture file, id, command name, why it is interesting)
WANTED = [
    ('real-gemini-cli', 'gemini-cli', 'gemini', 'competing /usr/local/bin/gemini shadows the nvm install'),
    ('real-corepack', 'inv-npm-7966ae5aa0edd5c0', 'corepack', 'duplicate corepack: nvm, Homebrew and /usr/local'),
    ('real-npm-latest', 'inv-npm-5fd9f77853b04aff', 'latest', 'accidental npm global named "latest"'),
    ('real-npm-to', 'inv-npm-98557abc7e6d5dbd', 'to', 'accidental npm global named "to"'),
    ('real-npm-update', 'inv-npm-b2e28c14a41df2f5', 'update', 'accidental npm global named "update"'),
    ('real-opencode', 'opencode', 'opencode', 'catalog item whose check failed'),
    ('real-java', 'java', 'java', 'catalog item whose check failed'),
    ('real-global-pnpm', 'global-pnpm', 'pnpm', 'library group whose check failed'),
    ('real-swift', 'swift', 'swift', 'status unknown'),
    ('real-app-cleanmymac', 'discovered-app-6b4e4fa6b07026dd', None, 'discovered app whose check failed'),
]
os.makedirs(out, exist_ok=True)
for name, item_id, command, why in WANTED:
    row = rows.get(item_id, {})
    item = check.get(item_id, {})
    if not row and not item:
        print('MISSING', item_id); continue
    ctx = {
        'id': item_id,
        'name': item.get('name') or row.get('name') or item_id,
        'category': item.get('category'),
        'ecosystem': row.get('ecosystem') or None,
        'handle': row.get('handle') or None,
        'root': row.get('root'),
        'commandName': command,
        'status': item.get('status') or 'listed',
        'observedVersion': item.get('currentVersionRaw') or None,
        'currentPlannedCommand': (re.sub(r"^PATH='[^']*' ", '', item.get('plannedCommand') or '')[:300]) or None,
        'competing': [{'path': c.get('path'), 'version': c.get('version'), 'ecosystem': c.get('ecosystem'), 'packageID': c.get('packageID')}
                      for c in row.get('competing', [])],
        'description': row.get('description'),
        'extraText': [],
    }
    ctx = {k: v for k, v in redact(ctx).items() if v is not None}
    doc = {'kind': 'real', 'why': why, 'context': ctx}
    json.dump(doc, open(os.path.join(out, name + '.json'), 'w'), indent=2, ensure_ascii=False)
    print('wrote', name)
