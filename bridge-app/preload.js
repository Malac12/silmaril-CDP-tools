const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('bridgeApi', {
  getSnapshot: () => ipcRenderer.invoke('bridge:getSnapshot'),
  sendPrompt: (prompt) => ipcRenderer.invoke('bridge:sendPrompt', prompt),
  cancel: () => ipcRenderer.invoke('bridge:cancel'),
  restart: () => ipcRenderer.invoke('bridge:restart'),
  updateSettings: (partial) => ipcRenderer.invoke('bridge:updateSettings', partial),
  approvePending: () => ipcRenderer.invoke('bridge:approvePending'),
  rejectPending: () => ipcRenderer.invoke('bridge:rejectPending'),
  openExternal: (url) => ipcRenderer.invoke('bridge:openExternal', url),
  onTranscript: (listener) => ipcRenderer.on('bridge:transcript', (_event, payload) => listener(payload)),
  onActivity: (listener) => ipcRenderer.on('bridge:activity', (_event, payload) => listener(payload)),
  onChromeState: (listener) => ipcRenderer.on('bridge:chrome-state', (_event, payload) => listener(payload)),
  onSessionState: (listener) => ipcRenderer.on('bridge:session-state', (_event, payload) => listener(payload)),
  onPendingApproval: (listener) => ipcRenderer.on('bridge:pending-approval', (_event, payload) => listener(payload)),
  onSettings: (listener) => ipcRenderer.on('bridge:settings', (_event, payload) => listener(payload))
});
