const { spawn } = require('child_process');
const path = require('path');

/**
 * Execute a command and return stdout, stderr, and exit code
 * @param {string} command - Command to execute
 * @param {string[]} args - Command arguments
 * @param {string} cwd - Working directory
 * @param {number} timeout - Timeout in ms (default 120000)
 * @returns {Promise<{exitCode: number, stdout: string, stderr: string}>}
 */
function execCommand(command, args = [], cwd = null, timeout = 120000) {
  return new Promise((resolve) => {
    const proc = spawn(command, args, {
      cwd: cwd || process.cwd(),
      shell: false,
      windowsHide: true
    });

    let stdout = '';
    let stderr = '';
    let timeoutId = null;

    if (timeout > 0) {
      timeoutId = setTimeout(() => {
        proc.kill();
      }, timeout);
    }

    proc.stdout.on('data', (data) => {
      stdout += data.toString();
    });

    proc.stderr.on('data', (data) => {
      stderr += data.toString();
    });

    proc.on('close', (code) => {
      if (timeoutId) clearTimeout(timeoutId);
      resolve({
        exitCode: code || 0,
        stdout: stdout.trim(),
        stderr: stderr.trim()
      });
    });

    proc.on('error', (err) => {
      if (timeoutId) clearTimeout(timeoutId);
      resolve({
        exitCode: 1,
        stdout: '',
        stderr: err.message
      });
    });
  });
}

/**
 * Check if git is available
 * @returns {Promise<boolean>}
 */
async function isGitAvailable() {
  const result = await execCommand('git', ['--version']);
  return result.exitCode === 0;
}

/**
 * Get current commit hash for a repository
 * @param {string} repoPath - Path to git repository
 * @returns {Promise<string|null>}
 */
async function getRepoVersion(repoPath) {
  const result = await execCommand('git', ['rev-parse', '--short', 'HEAD'], repoPath);
  return result.exitCode === 0 ? result.stdout : null;
}

/**
 * Check if repository has updates available
 * @param {string} repoPath - Path to git repository
 * @returns {Promise<{status: string, ahead: number, message: string}>}
 */
async function checkRepoUpdates(repoPath) {
  // Fetch updates
  const fetchResult = await execCommand('git', ['fetch', '--quiet', 'origin'], repoPath, 10000);

  if (fetchResult.exitCode !== 0) {
    return {
      status: 'error',
      ahead: 0,
      message: 'Failed to fetch updates'
    };
  }

  // Check ahead count
  const revListResult = await execCommand(
    'git',
    ['rev-list', 'HEAD..@{u}', '--count'],
    repoPath
  );

  if (revListResult.exitCode !== 0) {
    return {
      status: 'up-to-date',
      ahead: 0,
      message: 'No remote tracking branch'
    };
  }

  const ahead = parseInt(revListResult.stdout) || 0;

  if (ahead > 0) {
    return {
      status: 'update-available',
      ahead,
      message: `${ahead} commit${ahead > 1 ? 's' : ''} behind`
    };
  }

  return {
    status: 'up-to-date',
    ahead: 0,
    message: 'Up to date'
  };
}

/**
 * Update a git repository
 * @param {string} repoPath - Path to git repository
 * @returns {Promise<{success: boolean, message: string}>}
 */
async function updateRepo(repoPath) {
  const result = await execCommand('git', ['pull', '--ff-only'], repoPath);

  if (result.exitCode === 0) {
    return {
      success: true,
      message: 'Updated successfully'
    };
  }

  return {
    success: false,
    message: result.stderr || 'Update failed'
  };
}

/**
 * Check if winget is available
 * @returns {Promise<boolean>}
 */
async function isWingetAvailable() {
  const result = await execCommand('winget', ['--version']);
  return result.exitCode === 0;
}

/**
 * List installed winget packages
 * @returns {Promise<Array<{name: string, id: string, version: string}>>}
 */
async function listWingetPackages() {
  const result = await execCommand('winget', ['list', '--accept-source-agreements']);

  if (result.exitCode !== 0) {
    return [];
  }

  const packages = [];
  const lines = result.stdout.split('\n');

  // Skip header lines
  let startIndex = -1;
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].includes('Name') && lines[i].includes('Id')) {
      startIndex = i + 2; // Skip header and separator line
      break;
    }
  }

  if (startIndex === -1) return [];

  for (let i = startIndex; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line) continue;

    // Parse winget list output (space-separated columns)
    const parts = line.split(/\s{2,}/);
    if (parts.length >= 3) {
      packages.push({
        name: parts[0].trim(),
        id: parts[1].trim(),
        version: parts[2].trim()
      });
    }
  }

  return packages;
}

/**
 * Check if a winget package has updates
 * @param {string} packageId - Package ID
 * @returns {Promise<{hasUpdate: boolean, latestVersion: string|null}>}
 */
async function checkWingetUpdate(packageId) {
  // Prefer listing upgrades for this exact id
  const result = await execCommand('winget', [
    'upgrade',
    '--id',
    packageId,
    '--exact',
    '--accept-source-agreements'
  ]);

  const output = `${result.stdout}\n${result.stderr}`;

  if (
    /No applicable update found/i.test(output) ||
    /No installed package found/i.test(output) ||
    /No newer package versions are available/i.test(output)
  ) {
    return { hasUpdate: false, latestVersion: null };
  }

  // winget upgrade --id prints a table when an update exists
  const lines = result.stdout.split(/\r?\n/).map(l => l.trim()).filter(Boolean);
  let latestVersion = null;
  for (const line of lines) {
    if (/^Name\s+Id/i.test(line) || /^-{3,}/.test(line)) continue;
    if (line.toLowerCase().includes(packageId.toLowerCase()) || /\d+\.[\d.]+/.test(line)) {
      const parts = line.split(/\s{2,}/);
      if (parts.length >= 4) {
        latestVersion = parts[3].trim();
        break;
      }
      const versions = line.match(/\d+\.[\d.]+/g);
      if (versions && versions.length >= 2) {
        latestVersion = versions[versions.length - 1];
        break;
      }
    }
  }

  const hasUpdate =
    result.exitCode === 0 &&
    !/No applicable/i.test(output) &&
    (Boolean(latestVersion) || /Available/i.test(output) || lines.length > 2);

  return {
    hasUpdate,
    latestVersion: latestVersion || (hasUpdate ? 'newer' : null)
  };
}

/**
 * Update a winget package
 * @param {string} packageId - Package ID
 * @returns {Promise<{success: boolean, message: string}>}
 */
async function updateWingetPackage(packageId, source = null) {
  const args = ['upgrade', '--id', packageId, '--exact', '--accept-package-agreements', '--accept-source-agreements'];
  if (source) {
    args.push('--source', source);
  }
  const result = await execCommand('winget', args);

  if (result.exitCode === 0) {
    return {
      success: true,
      message: 'Updated successfully'
    };
  }

  return {
    success: false,
    message: result.stderr || result.stdout || 'Update failed'
  };
}

/**
 * Install a winget package
 * @param {string} packageId
 * @param {string|null} source
 * @returns {Promise<{success: boolean, message: string}>}
 */
async function installWingetPackage(packageId, source = null) {
  const args = ['install', '--id', packageId, '--exact', '--accept-package-agreements', '--accept-source-agreements'];
  if (source) {
    args.push('--source', source);
  }
  const result = await execCommand('winget', args, null, 300000);

  if (result.exitCode === 0) {
    return {
      success: true,
      message: 'Installed successfully'
    };
  }

  return {
    success: false,
    message: result.stderr || result.stdout || 'Install failed'
  };
}

module.exports = {
  execCommand,
  isGitAvailable,
  getRepoVersion,
  checkRepoUpdates,
  updateRepo,
  isWingetAvailable,
  listWingetPackages,
  checkWingetUpdate,
  updateWingetPackage,
  installWingetPackage
};
