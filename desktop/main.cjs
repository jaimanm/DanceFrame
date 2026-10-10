'use strict';
const {app,BrowserWindow,Menu,dialog,ipcMain,protocol,net,shell}=require('electron');
const fs=require('node:fs/promises');
const fsSync=require('node:fs');
const {Readable}=require('node:stream');
const path=require('node:path');
const {pathToFileURL}=require('node:url');
const {randomUUID}=require('node:crypto');
const video=require('./video.cjs');
protocol.registerSchemesAsPrivileged([{scheme:'danceframe',privileges:{standard:true,secure:true,supportFetchAPI:true,stream:true}}]);
let window,exportPending=false;
const media=new Map(),jobs=new Map();
const root=path.join(__dirname,'..','static');
const mimeTypes={
 '.mp4':'video/mp4',
 '.mov':'video/quicktime',
 '.m4v':'video/mp4',
 '.webm':'video/webm',
 '.mkv':'video/x-matroska',
 '.html':'text/html; charset=utf-8',
 '.js':'application/javascript; charset=utf-8',
 '.css':'text/css; charset=utf-8'
};
const binary=name=>path.join(app.isPackaged?process.resourcesPath:path.join(__dirname,'..','build-resources'),'binaries',name);
const active=()=>exportPending||[...jobs.values()].some(j=>j.status==='running');
function handle(name,fn){ipcMain.handle(name,async(event,data)=>{
 if(event.sender!==window?.webContents||event.senderFrame!==window.webContents.mainFrame||!event.senderFrame.url.startsWith('danceframe://app/'))return {error:'Unauthorized request.'};
 try{return await fn(data);}catch(e){return {error:e.message};}
});}
function menus(){
 const send=action=>window?.webContents.send('menu:action',action);
 Menu.setApplicationMenu(Menu.buildFromTemplate([
  {label:'DanceFrame',submenu:[{role:'about'},{type:'separator'},{role:'hide'},{role:'hideOthers'},{role:'unhide'},{type:'separator'},{role:'quit'}]},
  {label:'File',submenu:[{label:'Open Video…',accelerator:'CmdOrCtrl+O',click:()=>send('open')},{label:'Load Tracking Project…',accelerator:'CmdOrCtrl+Shift+O',click:()=>send('load')},{label:'Save Tracking Project…',accelerator:'CmdOrCtrl+S',click:()=>send('save')},{type:'separator'},{label:'Export Vertical Video…',accelerator:'CmdOrCtrl+E',click:()=>send('export')},{type:'separator'},{role:'close'}]},
  {label:'Edit',submenu:[{label:'Undo Tracking Point',accelerator:'CmdOrCtrl+Z',click:()=>send('undo')},{type:'separator'},{role:'cut'},{role:'copy'},{role:'paste'},{role:'selectAll'}]},
  {label:'View',submenu:[{role:'resetZoom'},{role:'zoomIn'},{role:'zoomOut'},{type:'separator'},{role:'togglefullscreen'}]},
  {role:'windowMenu'}
 ]));
}
function createWindow(){
 window=new BrowserWindow({width:1340,height:960,minWidth:900,minHeight:680,title:'DanceFrame',backgroundColor:'#111214',show:false,webPreferences:{preload:path.join(__dirname,'preload.cjs'),nodeIntegration:false,contextIsolation:true,sandbox:true}});
 window.webContents.setWindowOpenHandler(()=>({action:'deny'}));
 window.webContents.on('will-navigate',(event,url)=>{if(url!=='danceframe://app/')event.preventDefault();});
 window.webContents.session.setPermissionRequestHandler((_,__,callback)=>callback(false));
 window.webContents.session.setPermissionCheckHandler(()=>false);
 window.on('close',event=>{if(active()){
  const response=dialog.showMessageBoxSync(window,{type:'question',buttons:['Keep Editing','Cancel Export and Close'],defaultId:0,cancelId:0,message:'An export is still running.'});
  if(response===0)event.preventDefault();else for(const j of jobs.values())if(j.process){j.cancelled=true;j.process.kill();}
 }});
 window.once('ready-to-show',()=>window.show());window.on('closed',()=>window=null);
 window.loadURL('danceframe://app/');menus();
}
if(!app.requestSingleInstanceLock())app.quit();else{
 app.on('second-instance',()=>{if(window){if(window.isMinimized())window.restore();window.show();window.focus();}});
 app.whenReady().then(async()=>{
  app.setAboutPanelOptions({applicationName:'DanceFrame',applicationVersion:'1.0.0',copyright:'Local video reframing • Manual tracking and trimming'});
  protocol.handle('danceframe',async request=>{
   const url=new URL(request.url);
   let file,fileSize;
   if(url.hostname==='app'&&url.pathname.startsWith('/media/')){
    const item=media.get(url.pathname.slice(7));
    if(item){file=item.path;fileSize=item.size;}
   }else if(url.hostname==='app'){
    const name=url.pathname==='/'?'index.html':url.pathname.slice(1);
    if(!['index.html','app.js','style.css'].includes(name))return new Response('Not found',{status:404});
    file=path.join(root,name);
   }
   if(!file)return new Response('Not found',{status:404});
   try{
    if(fileSize===undefined)fileSize=(await fs.stat(file)).size;
    const mime=mimeTypes[path.extname(file).toLowerCase()]||'application/octet-stream';
    const rangeHeader=request.headers.get('range');
    if(rangeHeader){
     const match=/bytes=(\d*)-(\d*)/.exec(rangeHeader);
     if(match){
      let start=match[1]?parseInt(match[1],10):0;
      let end=match[2]?parseInt(match[2],10):fileSize-1;
      if(!match[1]&&match[2]){
       start=Math.max(0,fileSize-parseInt(match[2],10));
       end=fileSize-1;
      }
      if(start>end||start>=fileSize){
       return new Response('Requested range not satisfiable',{status:416,headers:{'Content-Range':`bytes */${fileSize}`}});
      }
      end=Math.min(end,fileSize-1);
      const chunkSize=end-start+1;
      const stream=Readable.toWeb(fsSync.createReadStream(file,{start,end}));
      return new Response(stream,{
       status:206,
       headers:{
        'Content-Type':mime,
        'Content-Range':`bytes ${start}-${end}/${fileSize}`,
        'Content-Length':String(chunkSize),
        'Accept-Ranges':'bytes'
       }
      });
     }
    }
    const stream=Readable.toWeb(fsSync.createReadStream(file));
    return new Response(stream,{
     status:200,
     headers:{
      'Content-Type':mime,
      'Content-Length':String(fileSize),
      'Accept-Ranges':'bytes'
     }
    });
   }catch{
    return new Response('Not found',{status:404});
   }
  });
  handle('video:open',async()=>{
   if(active())throw Error('Finish or cancel the export before opening another video.');
   const result=await dialog.showOpenDialog(window,{title:'Open a landscape video',properties:['openFile'],filters:[{name:'Videos',extensions:['mp4','mov','m4v','webm','mkv']}]});
   if(result.canceled)return null;
   const file=result.filePaths[0],meta=await video.probe(binary('ffprobe'),file),id=randomUUID();
   const stat=await fs.stat(file);
   const item={...meta,id,name:path.basename(file),path:file,size:stat.size,url:`danceframe://app/media/${id}`};
   media.clear();media.set(id,item);const {path:_,size:__, ...publicMeta}=item;return publicMeta;
  });
  handle('project:save',async data=>{
   if(!data||JSON.stringify(data).length>2*1024*1024)throw Error('Invalid project.');
   const result=await dialog.showSaveDialog(window,{title:'Save tracking project',defaultPath:(data.video?.name||'video')+'.danceframe.json',filters:[{name:'DanceFrame project',extensions:['json']}]});
   if(result.canceled)return null;
   const tmp=result.filePath+'.'+randomUUID()+'.tmp';
   try{await fs.writeFile(tmp,JSON.stringify(data,null,2));await fs.rename(tmp,result.filePath);}finally{await fs.rm(tmp,{force:true});}
   return {saved:true};
  });
  handle('project:open',async()=>{
   const result=await dialog.showOpenDialog(window,{title:'Load tracking project',properties:['openFile'],filters:[{name:'DanceFrame project',extensions:['json']}]});
   if(result.canceled)return null;
   if((await fs.stat(result.filePaths[0])).size>2*1024*1024)throw Error('Project file is too large.');
   return JSON.parse(await fs.readFile(result.filePaths[0],'utf8'));
  });
  handle('video:export',async data=>{
   if(active())throw Error('An export is already running.');
   const meta=media.get(data?.id);if(!meta)throw Error('Open a video first.');
   const checked=video.validate(data,meta);exportPending=true;
   try{
    const result=await dialog.showSaveDialog(window,{title:'Export vertical video',defaultPath:path.join(app.getPath('videos'),path.parse(meta.name).name+'-vertical.mp4'),filters:[{name:'MP4 video',extensions:['mp4']}],properties:['createDirectory','showOverwriteConfirmation']});
    if(result.canceled)return null;
    if(path.resolve(result.filePath)===path.resolve(meta.path))throw Error('Choose a different filename so your original video is preserved.');
    const cache=path.join(app.getPath('userData'),'render-cache');await fs.mkdir(cache,{recursive:true});
    const id=randomUUID(),job={status:'running',progress:0};jobs.set(id,job);
    video.render(binary('ffmpeg'),meta,checked,result.filePath,cache,job).catch(e=>Object.assign(job,{status:'error',error:e.message}));
    return {id};
   }finally{exportPending=false;}
  });
  handle('job:get',id=>{const job=jobs.get(id);if(!job)throw Error('Export not found.');const {process,path:_,...state}=job;return state;});
  handle('job:cancel',id=>{const j=jobs.get(id);if(j?.status==='running'){j.cancelled=true;j.process?.kill();}return {ok:true};});
  handle('job:reveal',id=>{const j=jobs.get(id);if(j?.status!=='done')throw Error('Export not found.');shell.showItemInFolder(j.path);return {ok:true};});
  createWindow();
 });
 app.on('activate',()=>{if(!window)createWindow();});
 app.on('window-all-closed',()=>app.quit());
 app.on('will-quit',()=>{for(const j of jobs.values())if(j.process){j.cancelled=true;j.process.kill();}});
}
