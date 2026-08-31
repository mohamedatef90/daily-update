const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('api', {
  loadSettings: () => ipcRenderer.invoke('load-settings'),
  saveSettings: (settings) => ipcRenderer.invoke('save-settings', settings),
  selectFolder: () => ipcRenderer.invoke('select-folder'),
  scanRepositories: (rootFolder, maxDepth) => ipcRenderer.invoke('scan-repositories', rootFolder, maxDepth),
  checkGitAvailable: () => ipcRenderer.invoke('check-git-available'),
  getRepoVersion: (repoPath) => ipcRenderer.invoke('get-repo-version', repoPath),
  checkRepoUpdates: (repoPath) => ipcRenderer.invoke('check-repo-updates', repoPath),
  updateRepo: (repoPath) => ipcRenderer.invoke('update-repo', repoPath),
  checkWingetAvailable: () => ipcRenderer.invoke('check-winget-available'),
  listWingetPackages: () => ipcRenderer.invoke('list-winget-packages'),
  checkWingetUpdate: (packageId) => ipcRenderer.invoke('check-winget-update', packageId),
  updateWingetPackage: (packageId, source) => ipcRenderer.invoke('update-winget-package', packageId, source),
  installWingetPackage: (packageId, source) => ipcRenderer.invoke('install-winget-package', packageId, source),
  getDefaultPaths: () => ipcRenderer.invoke('get-default-paths'),
  scanDetectors: (rootFolder, applicationFolders) => ipcRenderer.invoke('scan-detectors', rootFolder, applicationFolders),
  reloadConfigs: (rootFolder, maxDepth, applicationFolders) => ipcRenderer.invoke('reload-configs', rootFolder, maxDepth, applicationFolders),
  showConfirmDialog: (message) => ipcRenderer.invoke('show-confirm-dialog', message)
});
