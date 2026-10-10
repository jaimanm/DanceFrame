const {contextBridge,ipcRenderer}=require('electron');
const invoke=async(name,data)=>{const r=await ipcRenderer.invoke(name,data);if(r?.error)throw Error(r.error);return r;};
contextBridge.exposeInMainWorld('danceframe',{
 openVideo:()=>invoke('video:open'),
 saveProject:data=>invoke('project:save',data),
 loadProject:()=>invoke('project:open'),
 exportVideo:data=>invoke('video:export',data),
 getJob:id=>invoke('job:get',id),
 cancel:id=>invoke('job:cancel',id),
 reveal:id=>invoke('job:reveal',id),
 onMenu:callback=>ipcRenderer.on('menu:action',(_,action)=>callback(action))
});
