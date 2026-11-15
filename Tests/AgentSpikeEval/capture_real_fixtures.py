#!/usr/bin/env python3 -I
"""Builds the REAL fixtures of the AI eval from this Mac's `--discover --json` and `--check --json` output.
Home paths and the account name are replaced with `~` / `<user>` before anything is written.
Two sets: `spike` (the 10 items used in the ADR-003 spike, files `real-*`) and `holdout` (15 items that were
NOT used in the spike, files `holdout-*`, added in AI-1).
Usage: capture_real_fixtures.py <discover.json> <check.json> <out-dir> [spike|holdout]"""
import json, os, re, sys

discover = json.load(open(sys.argv[1]))
check = {i['id']: i for i in json.load(open(sys.argv[2]))}
out = sys.argv[3]
which_set = sys.argv[4] if len(sys.argv) > 4 else 'spike'
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
# Hold-out set: items the spike never looked at. commandName is the item's executable (a few differ from
# the package name: @angular/cli installs `ng`, typescript installs `tsc`).
HOLDOUT = [
    ('holdout-npm-angular-cli', 'inv-npm-188c96d1cd71afcb', 'ng', 'npm global in /usr/local, the executable name differs from the package'),
    ('holdout-npm-n', 'inv-npm-e443f38dacb936ce', 'n', 'npm global named with one letter (a Node version manager)'),
    ('holdout-npm-sql-cli', 'inv-npm-fb79aaaf7bf4c74b', 'sql-cli', 'obscure npm global in /usr/local'),
    ('holdout-npm-typescript', 'inv-npm-9a673d111345ed47', 'tsc', 'common npm global in /usr/local'),
    ('holdout-npm-clawdhub', 'inv-npm-226df45e1553d7ae', 'clawdhub', 'npm global under nvm'),
    ('holdout-npm-figma-use', 'inv-npm-4d688d92e4061c74', 'figma-use', 'npm global under nvm'),
    ('holdout-brew-cliclick', 'inv-brew-96f4d4319f0297cf', 'cliclick', 'Homebrew formula'),
    ('holdout-brew-wacli', 'inv-brew-96a8bac99d58ae0d', 'wacli', 'Homebrew formula from a tap'),
    ('holdout-brew-ollama', 'inv-brew-1ab24e35efc7a68f', 'ollama', 'Homebrew formula that is also an app'),
    ('holdout-uv-nano-pdf', 'inv-uv-bf2d835829783457', 'nano-pdf', 'uv tool'),
    ('holdout-uv-browser-use', 'inv-uv-ba2c4022c4c1dcfc', 'browser-use', 'uv tool'),
    ('holdout-app-edits', 'discovered-app-1a49963794149232', None, 'discovered app whose check failed'),
    ('holdout-app-chatgpt', 'chatgpt', None, 'catalog app whose check failed'),
    ('holdout-lib-global-yarn', 'global-yarn', 'yarn', 'library group whose check failed'),
    ('holdout-lib-pip-packages', 'pip-packages', 'pip3', 'library group whose check failed'),
]
if which_set == 'holdout':
    WANTED = HOLDOUT

def app_path(planned):
    match = re.search(r"/[^'\"]+\.app", planned or '')
    return match.group(0) if match else None

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
        'packageID': row.get('packageID') or None,
        'appPath': app_path(item.get('plannedCommand')),
        'status': item.get('status') or 'listed',
        'observedVersion': item.get('currentVersionRaw') or None,
        'currentPlannedCommand': (re.sub(r"^PATH='[^']*' ", '', item.get('plannedCommand') or '')[:300]) or None,
        'competing': [{'path': c.get('path'), 'version': c.get('version'), 'ecosystem': c.get('ecosystem'), 'packageID': c.get('packageID')}
                      for c in row.get('competing', [])],
        'description': row.get('description'),
        'extraText': [],
    }
    ctx = {k: v for k, v in redact(ctx).items() if v is not None}
    doc = {'kind': 'real' if which_set == 'spike' else 'holdout', 'why': why, 'context': ctx}
    json.dump(doc, open(os.path.join(out, name + '.json'), 'w'), indent=2, ensure_ascii=False)
    print('wrote', name)
