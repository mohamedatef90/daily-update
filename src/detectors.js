const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawn } = require('child_process');
const { expandPath } = require('./pathUtils');
const { findStorePackageFolder, findMainExe, discoverApps, discoverCliTools } = require('./appScanner');

const DETECTORS_PATH = path.join(__dirname, 'detectors.json');

/**
 * Resolve a path that may include a simple * wildcard in the last segment
 * @param {string} rawPath
 * @returns {string|null} First matching path or null
 */
function resolvePathPattern(rawPath) {
  const expanded = expandPath(rawPath);
  if (!expanded.includes('*')) {
    return fs.existsSync(expanded) ? expanded : null;
  }

  const dir = path.dirname(expanded);
  const pattern = path.basename(expanded);
  if (!fs.existsSync(dir)) return null;

  try {
    const regex = new RegExp('^' + pattern.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*') + '$', 'i');
    const match = fs.readdirSync(dir).find(name => regex.test(name));
    if (!match) return null;
    const full = path.join(dir, match);
    return fs.existsSync(full) ? full : null;
  } catch {
    return null;
  }
}

/**
 * Run a command and capture stdout
 * @param {string} command
 * @param {string[]} args
 * @param {number} timeout
 * @returns {Promise<{exitCode: number, stdout: string, stderr: string}>}
 */
function runCommand(command, args = [], timeout = 15000) {
  return new Promise((resolve) => {
    const proc = spawn(command, args, {
      shell: false,
      windowsHide: true,
      env: process.env
    });

    let stdout = '';
    let stderr = '';
    let timeoutId = null;

    if (timeout > 0) {
      timeoutId = setTimeout(() => {
        try { proc.kill(); } catch { /* ignore */ }
      }, timeout);
    }

    proc.stdout.on('data', (data) => { stdout += data.toString(); });
    proc.stderr.on('data', (data) => { stderr += data.toString(); });

    proc.on('close', (code) => {
      if (timeoutId) clearTimeout(timeoutId);
      resolve({ exitCode: code || 0, stdout: stdout.trim(), stderr: stderr.trim() });
    });

    proc.on('error', (err) => {
      if (timeoutId) clearTimeout(timeoutId);
      resolve({ exitCode: 1, stdout: '', stderr: err.message });
    });
  });
}

/**
 * Find a command on PATH via where.exe
 * @param {string} command
 * @returns {Promise<string|null>}
 */
async function findCommand(command) {
  const result = await runCommand('where.exe', [command], 8000);
  if (result.exitCode !== 0 || !result.stdout) return null;
  const first = result.stdout.split(/\r?\n/).map(l => l.trim()).find(Boolean);
  return first || null;
}

/**
 * Load detector definitions
 * @returns {Array}
 */
function loadDetectors() {
  const raw = fs.readFileSync(DETECTORS_PATH, 'utf8');
  const data = JSON.parse(raw);
  return data.items || [];
}

/**
 * Read version from an exe via PowerShell FileVersionInfo
 * @param {string} exePath
 * @returns {Promise<string|null>}
 */
async function getExeVersion(exePath) {
  if (!exePath || !fs.existsSync(exePath)) return null;

  // Electron apps often ship package.json next to the binary
  const pkgCandidates = [
    path.join(path.dirname(exePath), 'resources', 'app', 'package.json'),
    path.join(path.dirname(exePath), 'resources', 'app.asar.unpacked', 'package.json')
  ];
  for (const pkg of pkgCandidates) {
    try {
      if (fs.existsSync(pkg)) {
        const json = JSON.parse(fs.readFileSync(pkg, 'utf8'));
        if (json.version) return String(json.version);
      }
    } catch {
      // continue
    }
  }

  const ps = `(Get-Item -LiteralPath '${exePath.replace(/'/g, "''")}').VersionInfo.ProductVersion`;
  const result = await runCommand('powershell.exe', ['-NoProfile', '-Command', ps], 10000);
  if (result.exitCode === 0 && result.stdout) {
    return result.stdout.split(/\r?\n/)[0].trim() || null;
  }
  return null;
}

/**
 * Get version for a detector that was found
 * @param {object} detector
 * @param {{installPath?: string|null, commandPath?: string|null}} found
 * @returns {Promise<string|null>}
 */
async function getVersion(detector, found) {
  const versionArgs = detector.versionCommand ? detector.versionCommand.slice(1) : ['--version'];

  async function runVersion(command, args = versionArgs) {
    const result = await runCommand(command, args, 10000);
    if (result.exitCode !== 0 || !result.stdout) return null;
    const text = result.stdout.split(/\r?\n/)[0].trim();
    if (!text) return null;
    return text
      .replace(/^.*?version\s+is\s+/i, '')
      .replace(/^.*?version\s+/i, '')
      .trim() || text;
  }

  if (detector.versionFrom === 'command' && detector.versionCommand) {
    const [cmd] = detector.versionCommand;
    const resolved = found.commandPath || found.installPath;

    if (resolved && /\.(cmd|bat)$/i.test(resolved)) {
      const version = await runVersion('cmd.exe', ['/c', resolved, ...versionArgs]);
      if (version) return version;
    }

    if (resolved && /\.exe$/i.test(resolved)) {
      const version = await runVersion(resolved, versionArgs);
      if (version) return version;
    }

    const version = await runVersion(cmd, versionArgs);
    if (version) return version;
  }

  if (found.installPath) {
    const version = await getExeVersion(found.installPath);
    if (version) return version;
  }

  if (found.commandPath && /\.exe$/i.test(found.commandPath)) {
    const version = await getExeVersion(found.commandPath);
    if (version) return version;
  }

  return null;
}

/**
 * Check whether a detector is installed
 * @param {object} detector
 * @param {Array<{id: string, name: string, version: string}>} wingetPackages
 * @returns {Promise<{installed: boolean, installPath: string|null, commandPath: string|null, wingetMatch: object|null}>}
 */
async function detectOne(detector, wingetPackages = [], applicationFolders = []) {
  const detect = detector.detect || {};
  let installPath = null;
  let commandPath = null;
  let wingetMatch = null;
  let storePackagePath = null;

  // Path-based detection
  if (Array.isArray(detect.paths)) {
    for (const p of detect.paths) {
      const resolved = resolvePathPattern(p);
      if (resolved) {
        installPath = resolved;
        break;
      }
    }
  }

  // Microsoft Store package folders (Claude, ChatGPT, Codex, etc.)
  const packagePrefixes = detect.packagePrefixes || [];
  if (!installPath && packagePrefixes.length) {
    storePackagePath = findStorePackageFolder(packagePrefixes);
    if (storePackagePath) {
      const hints = (detect.appName ? [detect.appName] : [detector.name]).filter(Boolean);
      installPath = findMainExe(storePackagePath, hints) || storePackagePath;
    }
  }

  // Scan configured application folders for appName match
  if (!installPath && detect.appName && applicationFolders.length) {
    for (const folder of applicationFolders) {
      const expanded = expandPath(folder);
      if (!fs.existsSync(expanded)) continue;
      try {
        const entries = fs.readdirSync(expanded, { withFileTypes: true });
        for (const entry of entries) {
          if (!entry.isDirectory()) continue;
          if (!entry.name.toLowerCase().includes(detect.appName.toLowerCase())) continue;
          const candidate = findMainExe(path.join(expanded, entry.name), [detect.appName]);
          if (candidate) {
            installPath = candidate;
            break;
          }
        }
      } catch {
        // skip unreadable folders
      }
      if (installPath) break;
    }
  }

  // Command-based detection
  const commands = detect.commands || [];
  for (const cmd of commands) {
    const found = await findCommand(cmd);
    if (found) {
      commandPath = found;
      break;
    }
  }

  // Winget package match (by id or prefix list)
  const prefixes = [
    ...(detector.wingetId ? [detector.wingetId] : []),
    ...packagePrefixes
  ].map(s => s.toLowerCase());

  if (prefixes.length && wingetPackages.length) {
    wingetMatch = wingetPackages.find(pkg => {
      const id = (pkg.id || '').toLowerCase();
      const name = (pkg.name || '').toLowerCase();
      return prefixes.some(prefix =>
        id === prefix ||
        id.startsWith(prefix) ||
        name.includes(prefix.replace(/\./g, ' '))
      );
    }) || null;
  }

  const installed = Boolean(installPath || commandPath || wingetMatch || storePackagePath);

  return { installed, installPath, commandPath, wingetMatch, storePackagePath };
}

/**
 * Scan all bundled detectors and return every catalog item (installed or not).
 * @param {Array<{id: string, name: string, version: string}>} [wingetPackages]
 * @param {string} [rootFolder]
 * @returns {Promise<Array>}
 */
async function scanDetectors(wingetPackages = [], rootFolder = '', applicationFolders = []) {
  const detectors = loadDetectors();
  const items = [];
  const knownPaths = new Set();

  for (const detector of detectors) {
    const expandedDetector = expandDetectorPaths(detector, rootFolder);
    const result = await detectOne(expandedDetector, wingetPackages, applicationFolders);

    let version = null;
    let status = 'not-installed';
    let message = 'Not installed';

    if (result.installed) {
      version =
        (result.wingetMatch && result.wingetMatch.version) ||
        (await getVersion(expandedDetector, result)) ||
        null;
      status = 'unchecked';
      message = null;
      if (result.installPath) knownPaths.add(result.installPath.toLowerCase());
      if (result.commandPath) knownPaths.add(result.commandPath.toLowerCase());
    }

    items.push({
      id: detector.id,
      name: detector.name,
      category: detector.category,
      description: detector.description || '',
      type: 'detector',
      source: 'bundled',
      wingetId: detector.wingetId || (result.wingetMatch && result.wingetMatch.id) || null,
      wingetSource: detector.wingetSource || null,
      path: result.installPath || result.commandPath || result.storePackagePath || null,
      installed: result.installed,
      version,
      status,
      latestVersion: null,
      message,
      selected: false
    });
  }

  const discoveredApps = discoverApps(applicationFolders, knownPaths);
  const catalogIds = new Set(items.map(i => i.id));
  const catalogNames = new Set(items.map(i => i.name.toLowerCase()));

  for (const app of discoveredApps) {
    if (catalogNames.has(app.name.toLowerCase())) continue;
    items.push(app);
  }

  const discoveredClis = discoverCliTools(knownPaths, catalogIds, catalogNames);
  for (const cli of discoveredClis) {
    if (catalogIds.has(cli.id) || catalogNames.has(cli.name.toLowerCase())) continue;
    items.push(cli);
  }

  return items.sort((a, b) => {
    if (a.category !== b.category) return a.category.localeCompare(b.category);
    return a.name.localeCompare(b.name);
  });
}

/**
 * Replace {ROOT} placeholders in detector paths
 * @param {object} detector
 * @param {string} rootFolder
 * @returns {object}
 */
function expandDetectorPaths(detector, rootFolder) {
  const root = rootFolder || os.homedir();
  const detect = detector.detect || {};
  if (!Array.isArray(detect.paths)) return detector;

  const paths = detect.paths.map(p => p.replace(/\{ROOT\}/g, root));
  return {
    ...detector,
    detect: { ...detect, paths }
  };
}

module.exports = {
  loadDetectors,
  scanDetectors,
  detectOne,
  expandPath,
  expandDetectorPaths,
  resolvePathPattern,
  findCommand,
  DETECTORS_PATH
};
