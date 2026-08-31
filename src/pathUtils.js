const path = require('path');
const os = require('os');

/**
 * Expand Windows env vars and ~ in a path string
 * @param {string} rawPath
 * @returns {string}
 */
function expandPath(rawPath) {
  if (!rawPath) return rawPath;
  let expanded = rawPath.replace(/%([^%]+)%/g, (_, name) => {
    return process.env[name] || process.env[name.toUpperCase()] || process.env[name.toLowerCase()] || `%${name}%`;
  });
  if (expanded.startsWith('~/') || expanded.startsWith('~\\')) {
    expanded = path.join(os.homedir(), expanded.slice(2));
  } else if (expanded === '~') {
    expanded = os.homedir();
  }
  return expanded;
}

module.exports = { expandPath };
