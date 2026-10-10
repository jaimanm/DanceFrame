'use strict';
const $ = id => document.getElementById(id);
const video = $('video'), canvas = $('overlay'), preview = $('preview');
let meta = null, points = [], history = [], selected = null, dragging = false, scrubbing = false, job = null, trim = {start:0,end:0};
const clamp = (v, a=0, b=1) => Math.max(a, Math.min(b, v));
const time = t => `${String(Math.floor(t/60)).padStart(2,'0')}:${(t%60).toFixed(3).padStart(6,'0')}`;
function notice(text, error=false) { $('notice').textContent=text; $('notice').classList.toggle('error',error); }
function key() { return 'danceframe:'+meta.name+':'+meta.width+':'+meta.duration; }
function project() { return {version:1, video:{name:meta.name,width:meta.width,height:meta.height,duration:meta.duration},mode:$('mode').value,points,trim}; }
function persist() { if(meta) { try { localStorage.setItem(key(),JSON.stringify(project())); } catch {} } }
function remember() { history.push(JSON.stringify(points)); if(history.length>100) history.shift(); $('undo').disabled=false; }
function position(t) {
  if(!points.length) return .5;
  if(t<=points[0].t) return points[0].x;
  for(let i=1;i<points.length;i++) if(t<points[i].t) {
    const a=points[i-1],b=points[i]; let u=clamp((t-a.t)/(b.t-a.t));
    if($('mode').value==='smooth') u=u*u*(3-2*u);
    return a.x+(b.x-a.x)*u;
  }
  return points.at(-1).x;
}
function addPoint(x=position(video.currentTime), record=true) {
  if(!meta || video.readyState<2) return;
  if(record) remember();
  const t=clamp(video.currentTime,0,meta.duration);
  const existing=points.find(p=>Math.abs(p.t-t)<.5/meta.fps);
  if(existing) {existing.x=clamp(x);selected=existing.t;}
  else { points.push({t,x:clamp(x)}); points.sort((a,b)=>a.t-b.t); selected=t; }
  renderPoints(); persist(); draw();
}
function renderPoints() {
  $('pointCount').textContent=`${points.length} tracking point${points.length===1?'':'s'}`;
  $('markers').replaceChildren(); $('pointList').replaceChildren();
  points.forEach((p,i)=>{
    const marker=document.createElement('button'); marker.className='marker'; marker.style.left=`${p.t/meta.duration*100}%`;
    marker.title=`Point ${i+1} at ${time(p.t)}`;marker.setAttribute('aria-label',marker.title);
    marker.onclick=()=>seekPoint(p); $('markers').append(marker);
    const chip=document.createElement('div');chip.className='chip'+(p.t===selected?' selected':'');
    const seek=document.createElement('button');seek.textContent=`${String(i+1).padStart(2,'0')} · ${time(p.t)}`;seek.onclick=()=>seekPoint(p);
    const del=document.createElement('button');del.textContent='×';del.title='Delete point';del.setAttribute('aria-label',`Delete point ${i+1}`);
    del.onclick=()=>{remember();points.splice(i,1);selected=null;renderPoints();persist();draw();};
    chip.append(seek,del);$('pointList').append(chip);
  });
  $('export').disabled=!points.length||!!job;
  $('save').disabled=!meta;
  if(!points.length) $('pointList').innerHTML='<span class="muted">Click on yourself in the source video to add the first point.</span>';
}
function seekPoint(p) {video.pause();video.currentTime=p.t;selected=p.t;renderPoints();draw();}
function geometry() {
  const w=canvas.clientWidth,h=canvas.clientHeight;
  const scale=Math.min(w/meta.width,h/meta.height);
  return {scale,left:(w-meta.width*scale)/2,top:(h-meta.height*scale)/2,w:meta.width*scale,h:meta.height*scale};
}
function draw() {
  if(!meta||video.readyState<2) return;
  const dpr=window.devicePixelRatio||1, w=canvas.clientWidth,h=canvas.clientHeight;
  if(canvas.width!==Math.round(w*dpr)||canvas.height!==Math.round(h*dpr)){canvas.width=Math.round(w*dpr);canvas.height=Math.round(h*dpr);}
  const ctx=canvas.getContext('2d');ctx.setTransform(dpr,0,0,dpr,0,0);ctx.clearRect(0,0,w,h);
  const g=geometry(), x=Math.floor(position(video.currentTime)*(meta.width-meta.cropWidth)), left=g.left+x*g.scale, cw=meta.cropWidth*g.scale;
  ctx.fillStyle='rgba(0,0,0,.60)';ctx.fillRect(g.left,g.top,left-g.left,g.h);ctx.fillRect(left+cw,g.top,g.left+g.w-left-cw,g.h);
  ctx.strokeStyle='#ddff8f';ctx.lineWidth=1.7;ctx.strokeRect(left,g.top+1,cw,g.h-2);
  ctx.setLineDash([4,5]);ctx.strokeStyle='rgba(221,255,143,.4)';ctx.lineWidth=1;ctx.beginPath();ctx.moveTo(left+cw/2,g.top);ctx.lineTo(left+cw/2,g.top+g.h);ctx.stroke();ctx.setLineDash([]);
  ctx.fillStyle='#ddff8f';ctx.fillRect(left+8,g.top+9,63,20);ctx.fillStyle='#1a2116';ctx.font='600 10px sans-serif';ctx.fillText('YOUR CUT',left+14,g.top+23);
  preview.getContext('2d').drawImage(video,x,0,meta.cropWidth,meta.cropHeight,0,0,preview.width,preview.height);
  const displayTime=scrubbing?Number($('scrub').value):video.currentTime;
  $('clock').innerHTML=`${time(displayTime)} <em>/ ${time(meta.duration)}</em>`;
  if(!scrubbing)$('scrub').value=video.currentTime;
}
function loop(){if(meta&&!video.paused&&video.currentTime>=trim.end){video.pause();video.currentTime=trim.end;}draw();requestAnimationFrame(loop);}requestAnimationFrame(loop);
function moveCrop(event,record=false){
  const rect=canvas.getBoundingClientRect(),g=geometry();
  const sourceX=(event.clientX-rect.left-g.left)/g.scale;
  addPoint((sourceX-meta.cropWidth/2)/(meta.width-meta.cropWidth),record);
}
canvas.onpointerdown=e=>{if(!meta||video.readyState<2)return;video.pause();remember();dragging=true;canvas.setPointerCapture(e.pointerId);moveCrop(e);};
canvas.onpointermove=e=>{if(dragging)moveCrop(e);};
canvas.onpointerup=canvas.onpointercancel=()=>{dragging=false;};
async function api(url,data){const response=await fetch(url,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(data)});const result=await response.json();if(!response.ok)throw Error(result.error||'Request failed');return result;}
$('file').onchange=async event=>{
  const file=event.target.files[0];if(!file)return;
  if(job){notice('Finish or cancel the current export before opening another video.',true);return;}
  video.pause();notice(`Opening ${file.name}…`);$('file').disabled=true;
  try {
    const result=await new Promise((resolve,reject)=>{
      const xhr=new XMLHttpRequest();xhr.open('POST','/api/upload');xhr.setRequestHeader('X-Filename',encodeURIComponent(file.name));
      xhr.upload.onprogress=e=>{if(e.lengthComputable)notice(`Copying video locally… ${Math.round(e.loaded/e.total*100)}%`);};
      xhr.onload=()=>{try {const data=JSON.parse(xhr.responseText);xhr.status===200?resolve(data):reject(Error(data.error));}catch{reject(Error('Could not open the video.'));}};
      xhr.onerror=()=>reject(Error('Cannot reach the local server.'));xhr.send(file);
    });
    meta=result;trim={start:0,end:meta.duration};points=[];history=[];selected=null;$('undo').disabled=true;
    try {const saved=JSON.parse(localStorage.getItem(key()));if(saved)applyProject(saved);}catch{}
    video.src=meta.url;video.load();$('empty').hidden=true;$('previewEmpty').hidden=true;
    $('sourceInfo').textContent=`${meta.name} · ${meta.width} × ${meta.height} · ${meta.fps.toFixed(2)} fps`;
    $('scrub').max=meta.duration;$('scrub').step=1/meta.fps;$('endTime').textContent=time(meta.duration);
    ['play','back','forward','scrub','add','save','trimStart','trimEnd','setStart','setEnd','resetTrim'].forEach(id=>$(id).disabled=false);
    renderTrim();renderPoints();notice('Scrub to a moment, then click on yourself. Drag to fine-tune a tracking point.');
  }catch(error){notice(error.message,true);}finally{$('file').disabled=false;event.target.value='';}
};
video.onerror=()=>notice('Your browser cannot decode this video. Try Chrome or an H.264 MP4. The original file is unchanged.',true);
video.onplay=()=>$('play').textContent='Ⅱ';video.onpause=()=>$('play').textContent='▶';
function toggle(){if(meta){if(video.paused){if(video.currentTime<trim.start||video.currentTime>=trim.end-0.01)video.currentTime=trim.start;video.play().catch(e=>notice(e.message,true));}else video.pause();}}
function step(n){if(meta){video.pause();video.currentTime=clamp(video.currentTime+n/meta.fps,0,Math.max(0,meta.duration-1/meta.fps));draw();}}
$('play').onclick=toggle;$('back').onclick=()=>step(-1);$('forward').onclick=()=>step(1);
function applyScrub(t){
  if(!meta)return;
  video.pause();
  video.currentTime=clamp(t,0,meta.duration);
  $('scrub').value=video.currentTime;
  selected=null;
  draw();
}
$('scrub').onpointerdown=()=>{scrubbing=true;video.pause();};
window.addEventListener('pointerup',()=>{if(scrubbing){scrubbing=false;if(meta)$('scrub').value=video.currentTime;}});
window.addEventListener('pointercancel',()=>{scrubbing=false;});
$('scrub').oninput=()=>{
  if(!meta)return;
  video.pause();
  video.currentTime=Number($('scrub').value);
  selected=null;
  draw();
};
$('scrub').onchange=()=>{
  if(!meta)return;
  video.pause();
  video.currentTime=Number($('scrub').value);
  selected=null;
  draw();
};
$('timeline').onclick=e=>{
  if(e.target.closest('.marker')||e.target===$('scrub')||!meta)return;
  const rect=$('timeline').getBoundingClientRect();
  const frac=clamp((e.clientX-rect.left)/rect.width,0,1);
  applyScrub(frac*meta.duration);
};
$('speed').onchange=()=>video.playbackRate=Number($('speed').value);
$('add').onclick=()=>addPoint();$('mode').onchange=()=>{persist();draw();};
$('undo').onclick=()=>{if(history.length){points=JSON.parse(history.pop());selected=null;renderPoints();persist();$('undo').disabled=!history.length;}};
document.onkeydown=e=>{
  if(['INPUT','SELECT','TEXTAREA'].includes(document.activeElement.tagName)||!meta)return;
  if(e.code==='Space'){e.preventDefault();toggle();}
  if(e.code==='ArrowLeft'||e.code==='ArrowRight'){e.preventDefault();step((e.code==='ArrowLeft'?-1:1)*(e.shiftKey?10:1));}
  if(e.code==='KeyK'){e.preventDefault();addPoint();}
  if(e.code==='KeyZ'&&(e.metaKey||e.ctrlKey)){e.preventDefault();$('undo').click();}
};
$('save').onclick=()=>{
  const url=URL.createObjectURL(new Blob([JSON.stringify(project(),null,2)],{type:'application/json'}));
  const a=document.createElement('a');a.href=url;a.download=meta.name.replace(/\.[^.]+$/,'')+'.danceframe.json';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);notice('Tracking project saved. Reopen the same video and load this file to resume later.');
};
function applyProject(data){
  if(data.version!==1||!data.video||Math.abs(data.video.duration-meta.duration)>.1||data.video.width!==meta.width||data.video.height!==meta.height||data.video.name!==meta.name)throw Error('This project belongs to a different video. Open the matching original first.');
  if(!Array.isArray(data.points)||data.points.length>10000||data.points.some(p=>!Number.isFinite(p.t)||!Number.isFinite(p.x)||p.t<0||p.t>meta.duration||p.x<0||p.x>1))throw Error('Invalid tracking project.');
  const sorted=data.points.map(p=>({t:p.t,x:p.x})).sort((a,b)=>a.t-b.t);
  if(sorted.some((p,i)=>i&&p.t-sorted[i-1].t<.000001))throw Error('The project has duplicate point times.');
  const nextTrim=checkTrim(data.trim||{start:0,end:meta.duration});
  points=sorted;trim=nextTrim;$('mode').value=data.mode==='linear'?'linear':'smooth';
}
$('load').onchange=async e=>{
  try{if(!meta)throw Error('Open the original video first.');const file=e.target.files[0];if(!file)return;const data=JSON.parse(await file.text());remember();applyProject(data);selected=null;renderTrim();renderPoints();persist();notice('Tracking project loaded.');}catch(error){notice(error.message,true);}finally{e.target.value='';}
};
$('export').onclick=async()=>{
  video.pause();$('export').disabled=true;$('download').hidden=true;$('progress').hidden=false;$('progress').value=0;$('exportStatus').textContent='Preparing your vertical video…';
  try{const result=await api('/api/export',{id:meta.id,points,mode:$('mode').value,size:$('size').value,trim});job=result.id;$('cancel').hidden=false;poll();}catch(error){$('exportStatus').textContent=error.message;$('progress').hidden=true;renderPoints();}
};
async function poll(){
  try{const response=await fetch('/api/jobs/'+job);if(!response.ok)throw Error('Export status unavailable.');const state=await response.json();$('progress').value=state.progress;
    if(state.status==='running'){$('exportStatus').textContent=`Rendering… ${Math.round(state.progress*100)}% · You can continue adjusting points for your next export.`;setTimeout(poll,700);return;}
    if(state.status==='done'){$('exportStatus').textContent='Your vertical video is ready. Audio included when present in the original.';$('download').href=state.url;$('download').download=state.filename;$('download').hidden=false;}
    else $('exportStatus').textContent=state.error||'Export cancelled.';
    job=null;$('cancel').hidden=true;$('progress').hidden=true;renderPoints();
  }catch(error){$('exportStatus').textContent=error.message+' Retrying…';setTimeout(poll,3000);}
}
$('cancel').onclick=async()=>{if(job)try{await api('/api/cancel',{id:job});}catch(e){notice(e.message,true);}};

function checkTrim(value){
  const start=Number(value.start),end=Number(value.end);
  if(!Number.isFinite(start)||!Number.isFinite(end)||start<0||end>meta.duration||end-start<1/meta.fps)throw Error('Choose a trim range inside the video, at least one frame long.');
  return {start,end};
}
function renderTrim(){
  $('trimStart').value=trim.start.toFixed(3);$('trimEnd').value=trim.end.toFixed(3);
  $('trimStart').max=meta.duration;$('trimEnd').max=meta.duration;
  $('trimDuration').textContent=`${time(trim.end-trim.start)} kept`;
  $('trimShadeLeft').style.width=`${trim.start/meta.duration*100}%`;
  $('trimShadeRight').style.width=`${(meta.duration-trim.end)/meta.duration*100}%`;
}
function setTrim(start,end){
  if(!meta)return;
  try{trim=checkTrim({start,end});video.pause();renderTrim();persist();notice(`Export range: ${time(trim.start)} → ${time(trim.end)}. Tracking points keep their original times.`);}
  catch(e){notice(e.message,true);renderTrim();}
}
$('trimStart').onchange=()=>setTrim(Number($('trimStart').value),trim.end);
$('trimEnd').onchange=()=>setTrim(trim.start,Math.min(meta.duration,Number($('trimEnd').value)));
$('setStart').onclick=()=>setTrim(video.currentTime,trim.end);
$('setEnd').onclick=()=>setTrim(trim.start,video.currentTime);
$('resetTrim').onclick=()=>setTrim(0,meta.duration);
