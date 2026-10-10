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
function seekPoint(p) {video.pause();selected=p.t;seekVideo(p.t);renderPoints();draw();}
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
  const displayTime=scrubbing?Number($('scrub').value):video.currentTime;
  const g=geometry(), x=Math.floor(position(displayTime)*(meta.width-meta.cropWidth)), left=g.left+x*g.scale, cw=meta.cropWidth*g.scale;
  ctx.fillStyle='rgba(0,0,0,.60)';ctx.fillRect(g.left,g.top,left-g.left,g.h);ctx.fillRect(left+cw,g.top,g.left+g.w-left-cw,g.h);
  ctx.strokeStyle='#ddff8f';ctx.lineWidth=1.7;ctx.strokeRect(left,g.top+1,cw,g.h-2);
  ctx.setLineDash([4,5]);ctx.strokeStyle='rgba(221,255,143,.4)';ctx.lineWidth=1;ctx.beginPath();ctx.moveTo(left+cw/2,g.top);ctx.lineTo(left+cw/2,g.top+g.h);ctx.stroke();ctx.setLineDash([]);
  ctx.fillStyle='#ddff8f';ctx.fillRect(left+8,g.top+9,63,20);ctx.fillStyle='#1a2116';ctx.font='600 10px sans-serif';ctx.fillText('YOUR CUT',left+14,g.top+23);
  preview.getContext('2d').drawImage(video,x,0,meta.cropWidth,meta.cropHeight,0,0,preview.width,preview.height);
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
$('openVideo').onclick=async()=>{
  if(job){notice('Finish or cancel the current export before opening another video.',true);return;}
  video.pause();$('openVideo').disabled=true;
  try {
    const result=await window.danceframe.openVideo();if(!result)return;
    meta=result;trim={start:0,end:meta.duration};points=[];history=[];selected=null;$('undo').disabled=true;
    try {const saved=JSON.parse(localStorage.getItem(key()));if(saved)applyProject(saved);}catch{}
    video.src=meta.url;video.load();$('empty').hidden=true;$('previewEmpty').hidden=true;
    $('sourceInfo').textContent=`${meta.name} · ${meta.width} × ${meta.height} · ${meta.fps.toFixed(2)} fps`;
    $('scrub').max=meta.duration;$('scrub').step=1/meta.fps;$('endTime').textContent=time(meta.duration);
    ['play','back','forward','scrub','add','save','trimStart','trimEnd','setStart','setEnd','resetTrim'].forEach(id=>$(id).disabled=false);
    renderTrim();renderPoints();notice('Scrub to a moment, then click on yourself. Drag to fine-tune a tracking point.');
  }catch(error){notice(error.message,true);}finally{$('openVideo').disabled=false;}
};
video.onerror=()=>notice('This video codec cannot be previewed. Use an H.264 MP4. Your original file is unchanged.',true);
video.onplay=()=>$('play').textContent='Ⅱ';video.onpause=()=>$('play').textContent='▶';
let pendingTime=null;
function seekVideo(t){
  if(!meta||video.readyState<1)return;
  const target=clamp(t,0,meta.duration);
  if(video.seeking){
    pendingTime=target;
  }else{
    pendingTime=null;
    if(Math.abs(video.currentTime-target)>=0.0001){
      video.currentTime=target;
    }
  }
}
video.addEventListener('seeked',()=>{
  if(pendingTime!==null){
    const next=pendingTime;
    pendingTime=null;
    if(Math.abs(video.currentTime-next)>=0.0001){
      video.currentTime=next;
    }
  }
  draw();
});
function toggle(){if(meta){if(video.paused){if(video.currentTime<trim.start||video.currentTime>=trim.end-0.01)seekVideo(trim.start);video.play().catch(e=>notice(e.message,true));}else video.pause();}}
function step(n){if(meta){video.pause();seekVideo(clamp(video.currentTime+n/meta.fps,0,Math.max(0,meta.duration-1/meta.fps)));draw();}}
$('play').onclick=toggle;$('back').onclick=()=>step(-1);$('forward').onclick=()=>step(1);
function applyScrub(t){
  if(!meta)return;
  video.pause();
  const clamped=clamp(t,0,meta.duration);
  $('scrub').value=clamped;
  selected=null;
  seekVideo(clamped);
  draw();
}
$('scrub').onpointerdown=()=>{scrubbing=true;video.pause();};
window.addEventListener('pointerup',()=>{
  if(scrubbing){
    scrubbing=false;
    if(meta){
      seekVideo(Number($('scrub').value));
      draw();
    }
  }
});
window.addEventListener('pointercancel',()=>{
  if(scrubbing){
    scrubbing=false;
    if(meta)seekVideo(Number($('scrub').value));
  }
});
$('scrub').oninput=()=>{
  if(!meta)return;
  video.pause();
  selected=null;
  seekVideo(Number($('scrub').value));
  draw();
};
$('scrub').onchange=()=>{
  if(!meta)return;
  video.pause();
  selected=null;
  seekVideo(Number($('scrub').value));
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
$('save').onclick=async()=>{
  if(!meta)return;
  try{if(await window.danceframe.saveProject(project()))notice('Tracking project saved. Reopen the same video and load it to resume later.');}catch(e){notice(e.message,true);}
};
function applyProject(data){
  if(data.version!==1||!data.video||Math.abs(data.video.duration-meta.duration)>.1||data.video.width!==meta.width||data.video.height!==meta.height||data.video.name!==meta.name)throw Error('This project belongs to a different video. Open the matching original first.');
  if(!Array.isArray(data.points)||data.points.length>10000||data.points.some(p=>!Number.isFinite(p.t)||!Number.isFinite(p.x)||p.t<0||p.t>meta.duration||p.x<0||p.x>1))throw Error('Invalid tracking project.');
  const sorted=data.points.map(p=>({t:p.t,x:p.x})).sort((a,b)=>a.t-b.t);
  if(sorted.some((p,i)=>i&&p.t-sorted[i-1].t<.000001))throw Error('The project has duplicate point times.');
  const nextTrim=checkTrim(data.trim||{start:0,end:meta.duration});
  points=sorted;trim=nextTrim;$('mode').value=data.mode==='linear'?'linear':'smooth';
}
$('load').onclick=async()=>{
  try{if(!meta)throw Error('Open the original video first.');const data=await window.danceframe.loadProject();if(!data)return;remember();applyProject(data);selected=null;renderTrim();renderPoints();persist();notice('Tracking project loaded.');}catch(e){notice(e.message,true);}
};
$('export').onclick=async()=>{
  if(!meta||!points.length||job)return;
  video.pause();$('export').disabled=true;$('download').hidden=true;$('progress').hidden=false;$('progress').value=0;$('exportStatus').textContent='Choose where to save your vertical video…';
  try{const result=await window.danceframe.exportVideo({id:meta.id,points,mode:$('mode').value,size:$('size').value,trim});
    if(!result){$('exportStatus').textContent='';$('progress').hidden=true;renderPoints();return;}
    job=result.id;$('cancel').hidden=false;poll();
  }catch(e){$('exportStatus').textContent=e.message;$('progress').hidden=true;renderPoints();}
};
async function poll(){
  try{const state=await window.danceframe.getJob(job);$('progress').value=state.progress;
    if(state.status==='running'){$('exportStatus').textContent=`Rendering… ${Math.round(state.progress*100)}%`;setTimeout(poll,500);return;}
    if(state.status==='done'){$('exportStatus').textContent=`Saved ${state.filename}`;const completed=job;$('download').onclick=()=>window.danceframe.reveal(completed).catch(e=>notice(e.message,true));$('download').hidden=false;}
    else $('exportStatus').textContent=state.error||'Export cancelled.';
    job=null;$('cancel').hidden=true;$('progress').hidden=true;renderPoints();
  }catch(e){$('exportStatus').textContent=e.message;job=null;$('cancel').hidden=true;$('progress').hidden=true;renderPoints();}
}
$('cancel').onclick=async()=>{if(job)try{await window.danceframe.cancel(job);}catch(e){notice(e.message,true);}};
window.danceframe.onMenu(action=>{const ids={open:'openVideo',load:'load',save:'save',export:'export',undo:'undo'};if(ids[action])$(ids[action]).click();});

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
