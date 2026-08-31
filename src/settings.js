const fs = require('fs');
const path = require('path');
const os = require('os');

const APP_DATA_DIR = path.join(os.homedir(), '.daily-update-windows');
const SETTINGS_FILE = path.join(APP_DATA_DIR, 'settings.json');

const DEFAULT_SETTINGS = {
  hasCompletedSetup: false,
  rootFolder: '',
  applicationFolders: [],
  maxDepth: 4,
  autoCheckOnLaunch: true,
  rescanReposOnLaunch: true,
  lastScan: null,
  lastCheckDate: null,
  repositories: [],
  wingetPackages: [],
  detectors: [],
  history: []
};

function applyDefaults(settings) {
  const defaults = {
    homeFolder: require('os').homedir(),
    applicationFolders: [
      require('path').join(require('os').homedir(), 'AppData', 'Local', 'Programs'),
      process.env.ProgramFiles || 'C:\\Program Files',
      require('path').join(require('os').homedir(), 'AppData', 'Local', 'Packages')
    ]
  };

  if (!settings.rootFolder) {
    settings.rootFolder = defaults.homeFolder;
  }
  if (!settings.applicationFolders || settings.applicationFolders.length === 0) {
    settings.applicationFolders = defaults.applicationFolders;
  }
  return settings;
}

/**
 * Ensure app data directory exists
 */
function ensureDataDir() {
  if (!fs.existsSync(APP_DATA_DIR)) {
    fs.mkdirSync(APP_DATA_DIR, { recursive: true });
  }
}

/**
 * Load settings from disk
 * @returns {Object} Settings object
 */
function loadSettings() {
  ensureDataDir();

  if (!fs.existsSync(SETTINGS_FILE)) {
    return applyDefaults({ ...DEFAULT_SETTINGS });
  }

  try {
    const data = fs.readFileSync(SETTINGS_FILE, 'utf8');
    const parsed = JSON.parse(data);
    return applyDefaults({ ...DEFAULT_SETTINGS, ...parsed });
  } catch (err) {
    console.error('Failed to load settings:', err);
    return { ...DEFAULT_SETTINGS };
  }
}

/**
 * Save settings to disk
 * @param {Object} settings - Settings object to save
 */
function saveSettings(settings) {
  ensureDataDir();

  try {
    fs.writeFileSync(SETTINGS_FILE, JSON.stringify(settings, null, 2), 'utf8');
    return true;
  } catch (err) {
    console.error('Failed to save settings:', err);
    return false;
  }
}

module.exports = {
  loadSettings,
  saveSettings,
  applyDefaults,
  DEFAULT_SETTINGS,
  SETTINGS_FILE
};
