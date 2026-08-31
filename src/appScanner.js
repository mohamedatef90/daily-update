const fs = require('fs');
const path = require('path');
const os = require('os');
const { expandPath } = require('./pathUtils');

const DEVELOPER_KEYWORDS = [
  'cursor', 'claude', 'chatgpt', 'codex', 'warp', 'antigravity', 'zcode',
  'ollama', 'hermes', 'openclaw', 'open-claw', 'cua', 'vscode', 'code',
  'terminal', 'obsidian', 'docker', 'git', 'node', 'python', 'flutter',
  'android', 'jetbrains', 'postman', 'windsurf', 'aider', 'continue',
  'multicade', 'agent', 'moltbot'
];

const CLI_BIN_FOLDERS = [
  path.join(os.homedir(), 'AppData', 'Roaming', 'npm'),
  path.join(os.homedir(), '.local', 'bin'),
  path.join(os.homedir(), 'AppData', 'Local', 'Microsoft', 'WinGet', 'Links'),
  path.join(os.homedir(), 'AppData', 'Local', 'Programs')
];

const SKIP_EXE_FRAGMENTS = ['unins', 'uninstall', 'helper', 'update', 'elevate', 'crash', 'native-host', 'nativehost', 'host.exe'];

/**
 * Default Windows paths matching macOS onboarding intent
 */
function getDefaultPaths() {
  const homeFolder = os.homedir();
  return {
    homeFolder,
    applicationFolders: [
      path.join(homeFolder, 'AppData', 'Local', 'Programs'),
      process.env.ProgramFiles || 'C:\\Program Files',
      path.join(homeFolder, 'AppData', 'Local', 'Packages')
    ]
  };
}

/**
 * Find a Microsoft Store package folder by prefix
 * @param {string[]} prefixes
 * @returns {string|null}
 */
function findStorePackageFolder(prefixes = []) {
  const packagesDir = path.join(os.homedir(), 'AppData', 'Local', 'Packages');
  if (!fs.existsSync(packagesDir) || !prefixes.length) return null;

  try {
    const dirs = fs.readdirSync(packagesDir, { withFileTypes: true })
      .filter(d => d.isDirectory())
      .map(d => d.name);

    for (const prefix of prefixes) {
      const lower = prefix.toLowerCase();
      const match = dirs.find(name => name.toLowerCase().startsWith(lower));
      if (match) return path.join(packagesDir, match);
    }
  } catch {
    return null;
  }
  return null;
}

/**
 * Find main exe under a directory (shallow search)
 * @param {string} dir
 * @param {string[]} nameHints
 * @returns {string|null}
 */
function findMainExe(dir, nameHints = []) {
  if (!dir || !fs.existsSync(dir)) return null;

  const queue = [{ dir, depth: 0 }];
  const candidates = [];

  while (queue.length) {
    const { dir: current, depth } = queue.shift();
    if (depth > 4) continue;

    let entries;
    try {
      entries = fs.readdirSync(current, { withFileTypes: true });
    } catch {
      continue;
    }

    for (const entry of entries) {
      const full = path.join(current, entry.name);
      if (entry.isDirectory()) {
        queue.push({ dir: full, depth: depth + 1 });
        continue;
      }
      if (!entry.name.toLowerCase().endsWith('.exe')) continue;
      const lower = entry.name.toLowerCase();
      if (SKIP_EXE_FRAGMENTS.some(s => lower.includes(s))) continue;
      candidates.push(full);
    }
  }

  if (!candidates.length) return null;

  if (nameHints.length) {
    const hinted = candidates.find(c => {
      const base = path.basename(c).toLowerCase();
      return nameHints.some(h => base === `${h.toLowerCase()}.exe`);
    });
    if (hinted) return hinted;

    const partial = candidates.find(c => {
      const base = path.basename(c).toLowerCase();
      return nameHints.some(h => base.includes(h.toLowerCase()) && !base.includes('native'));
    });
    if (partial) return partial;
  }

  candidates.sort((a, b) => a.split(path.sep).length - b.split(path.sep).length);
  return candidates[0];
}

/**
 * Scan application folders for developer apps not in catalog
 * @param {string[]} applicationFolders
 * @param {Set<string>} knownPaths
 * @returns {Array}
 */
function discoverApps(applicationFolders = [], knownPaths = new Set()) {
  const discovered = [];
  const seen = new Set();

  for (const rawFolder of applicationFolders) {
    const folder = expandPath(rawFolder);
    if (!fs.existsSync(folder)) continue;

    let entries;
    try {
      entries = fs.readdirSync(folder, { withFileTypes: true });
    } catch {
      continue;
    }

    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      const appDir = path.join(folder, entry.name);
      if (seen.has(appDir.toLowerCase())) continue;

      const nameLower = entry.name.toLowerCase();
      if (!DEVELOPER_KEYWORDS.some(k => nameLower.includes(k))) continue;

      const exe = findMainExe(appDir, [entry.name.replace(/\s+/g, '')]);
      if (!exe || knownPaths.has(exe.toLowerCase())) continue;

      seen.add(appDir.toLowerCase());
      discovered.push({
        id: `discovered-app-${Buffer.from(exe).toString('base64').slice(0, 12)}`,
        name: entry.name,
        category: 'app',
        description: exe,
        type: 'detector',
        source: 'discovered',
        path: exe,
        installed: true,
        status: 'unchecked',
        version: null,
        latestVersion: null,
        message: null,
        selected: false
      });
    }
  }

  return discovered;
}

/**
 * Scan common CLI install folders for developer tools not in catalog
 * @param {Set<string>} knownPaths
 * @param {Set<string>} knownIds
 * @param {Set<string>} knownNames
 * @returns {Array}
 */
function discoverCliTools(knownPaths = new Set(), knownIds = new Set(), knownNames = new Set()) {
  const discovered = [];
  const seen = new Set();

  for (const rawFolder of CLI_BIN_FOLDERS) {
    const folder = expandPath(rawFolder);
    if (!fs.existsSync(folder)) continue;

    let entries;
    try {
      entries = fs.readdirSync(folder, { withFileTypes: true });
    } catch {
      continue;
    }

    for (const entry of entries) {
      if (!entry.isFile()) continue;
      const lower = entry.name.toLowerCase();
      if (!/\.(exe|cmd|bat|ps1)$/.test(lower)) continue;

      const baseName = lower.replace(/\.(exe|cmd|bat|ps1)$/, '');
      if (seen.has(baseName)) continue;
      if (knownIds.has(baseName) || knownNames.has(baseName)) continue;
      if (!DEVELOPER_KEYWORDS.some(k => baseName.includes(k))) continue;

      const fullPath = path.join(folder, entry.name);
      if (knownPaths.has(fullPath.toLowerCase())) continue;

      seen.add(baseName);
      const displayName = baseName.charAt(0).toUpperCase() + baseName.slice(1);

      discovered.push({
        id: `discovered-cli-${baseName.replace(/[^a-z0-9]+/g, '-')}`,
        name: displayName,
        category: 'cli',
        description: fullPath,
        type: 'detector',
        source: 'discovered',
        path: fullPath,
        installed: true,
        status: 'unchecked',
        version: null,
        latestVersion: null,
        message: null,
        selected: false
      });
    }
  }

  return discovered;
}

module.exports = {
  getDefaultPaths,
  findStorePackageFolder,
  findMainExe,
  discoverApps,
  discoverCliTools,
  DEVELOPER_KEYWORDS,
  CLI_BIN_FOLDERS
};
