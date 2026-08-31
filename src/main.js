const { app, BrowserWindow, ipcMain, dialog } = require('electron');
const path = require('path');
const { scanForRepositories, isValidDirectory } = require('./scanner');
const { scanDetectors } = require('./detectors');
const { getDefaultPaths } = require('./appScanner');
const {
  isGitAvailable,
  getRepoVersion,
  checkRepoUpdates,
  updateRepo,
  isWingetAvailable,
  listWingetPackages,
  checkWingetUpdate,
  updateWingetPackage,
  installWingetPackage
} = require('./updater');
const { loadSettings, saveSettings } = require('./settings');

let mainWindow;

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1100,
    height: 760,
    minWidth: 900,
    minHeight: 600,
    backgroundColor: '#edeaf5',
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
      preload: path.join(__dirname, 'preload.js')
    },
    icon: path.join(__dirname, '../assets/icon.png')
  });

  mainWindow.loadFile(path.join(__dirname, 'index.html'));
}

app.whenReady().then(() => {
  createWindow();

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow();
    }
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    app.quit();
  }
});

// IPC Handlers

ipcMain.handle('load-settings', async () => {
  return loadSettings();
});

ipcMain.handle('save-settings', async (event, settings) => {
  return saveSettings(settings);
});

ipcMain.handle('select-folder', async () => {
  const result = await dialog.showOpenDialog(mainWindow, {
    properties: ['openDirectory']
  });

  if (result.canceled || result.filePaths.length === 0) {
    return null;
  }

  return result.filePaths[0];
});

ipcMain.handle('scan-repositories', async (event, rootFolder, maxDepth) => {
  if (!isValidDirectory(rootFolder)) {
    throw new Error('Invalid directory');
  }

  const repos = scanForRepositories(rootFolder, maxDepth);
  return repos;
});

ipcMain.handle('check-git-available', async () => {
  return await isGitAvailable();
});

ipcMain.handle('get-repo-version', async (event, repoPath) => {
  return await getRepoVersion(repoPath);
});

ipcMain.handle('check-repo-updates', async (event, repoPath) => {
  return await checkRepoUpdates(repoPath);
});

ipcMain.handle('update-repo', async (event, repoPath) => {
  return await updateRepo(repoPath);
});

ipcMain.handle('check-winget-available', async () => {
  return await isWingetAvailable();
});

ipcMain.handle('list-winget-packages', async () => {
  return await listWingetPackages();
});

ipcMain.handle('check-winget-update', async (event, packageId) => {
  return await checkWingetUpdate(packageId);
});

ipcMain.handle('update-winget-package', async (event, packageId, source) => {
  return await updateWingetPackage(packageId, source || null);
});

ipcMain.handle('install-winget-package', async (event, packageId, source) => {
  return await installWingetPackage(packageId, source || null);
});

ipcMain.handle('get-default-paths', async () => {
  return getDefaultPaths();
});

ipcMain.handle('scan-detectors', async (event, rootFolder, applicationFolders) => {
  let wingetPackages = [];
  try {
    if (await isWingetAvailable()) {
      wingetPackages = await listWingetPackages();
    }
  } catch {
    // winget optional for path/command detection
  }
  return await scanDetectors(wingetPackages, rootFolder || '', applicationFolders || []);
});

ipcMain.handle('reload-configs', async (event, rootFolder, maxDepth, applicationFolders) => {
  let wingetPackages = [];
  try {
    if (await isWingetAvailable()) {
      wingetPackages = await listWingetPackages();
    }
  } catch {
    // optional
  }

  const folders = applicationFolders || getDefaultPaths().applicationFolders;
  const detectors = await scanDetectors(wingetPackages, rootFolder || '', folders);
  let repos = [];

  if (rootFolder && isValidDirectory(rootFolder)) {
    const repoPaths = scanForRepositories(rootFolder, maxDepth || 4);
    repos = repoPaths.map(repoPath => ({
      id: `repo-${Buffer.from(repoPath).toString('base64').slice(0, 12)}`,
      path: repoPath,
      name: path.basename(repoPath),
      category: 'repo',
      type: 'repo',
      description: repoPath,
      status: 'unchecked',
      version: null,
      latestVersion: null,
      message: null,
      selected: false,
      installed: true
    }));
  }

  return { detectors, repos };
});

ipcMain.handle('show-confirm-dialog', async (event, message) => {
  const result = await dialog.showMessageBox(mainWindow, {
    type: 'question',
    buttons: ['Cancel', 'Update'],
    defaultId: 1,
    title: 'Confirm Update',
    message: message
  });

  return result.response === 1; // Returns true if 'Update' was clicked
});
