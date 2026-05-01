const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('overlayBridge', {
  onUpdate:    (cb) => ipcRenderer.on('overlay-update',    (_, data) => cb(data)),
  onFadeOut:   (cb) => ipcRenderer.on('overlay-fade-out',  ()        => cb()),
  onCountdown: (cb) => ipcRenderer.on('overlay-countdown', (_, sec)  => cb(sec)),
  dismiss:     ()   => ipcRenderer.invoke('overlay-dismiss')
});
