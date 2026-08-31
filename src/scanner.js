const fs = require('fs');
const path = require('path');

const MAX_DEPTH = 4;
const SKIP_DIRS = new Set([
  '.git', 'node_modules', '.build', 'DerivedData', 'Pods', '.Trash',
  '.cache', 'vendor', '.venv', 'venv', '.npm', '.cargo', '.rustup',
  '.gradle', '.m2', '__pycache__', 'dist', 'build', 'target', '.next',
  '.nuxt', 'coverage', 'flutter', 'Flutter', 'android-sdk', 'Android',
  'android', 'homebrew', 'Cellar', 'sdk', 'SDKs', 'platform-tools',
  'cmdline-tools', '.vs', '.vscode', 'obj', 'bin', 'Debug', 'Release'
]);

/**
 * Recursively scan for git repositories
 * @param {string} rootPath - Root directory to scan
 * @param {number} maxDepth - Maximum depth to scan (default 4)
 * @returns {string[]} Array of git repository paths
 */
function scanForRepositories(rootPath, maxDepth = MAX_DEPTH) {
  const repos = [];
  const seen = new Set();

  function scan(currentPath, depth) {
    if (depth > maxDepth) return;

    try {
      const gitPath = path.join(currentPath, '.git');
      if (fs.existsSync(gitPath)) {
        const stats = fs.statSync(gitPath);
        if (stats.isDirectory() && !seen.has(currentPath)) {
          seen.add(currentPath);
          repos.push(currentPath);
        }
        return; // Don't scan inside git repos
      }

      const entries = fs.readdirSync(currentPath, { withFileTypes: true });

      for (const entry of entries) {
        if (!entry.isDirectory()) continue;

        const name = entry.name;
        if (SKIP_DIRS.has(name) || name.startsWith('.')) continue;

        const fullPath = path.join(currentPath, name);
        scan(fullPath, depth + 1);
      }
    } catch (err) {
      // Skip directories we can't read (permissions, etc.)
    }
  }

  scan(rootPath, 0);
  return repos.sort();
}

/**
 * Check if path is a valid directory
 * @param {string} dirPath - Directory path to check
 * @returns {boolean}
 */
function isValidDirectory(dirPath) {
  try {
    const stats = fs.statSync(dirPath);
    return stats.isDirectory();
  } catch (err) {
    return false;
  }
}

module.exports = {
  scanForRepositories,
  isValidDirectory,
  MAX_DEPTH,
  SKIP_DIRS
};
