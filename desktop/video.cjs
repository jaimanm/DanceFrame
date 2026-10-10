'use strict';
const {spawn,execFile}=require('node:child_process');
const {promisify}=require('node:util');
const fs=require('node:fs/promises');
const path=require('node:path');
const {randomUUID}=require('node:crypto');
const exec=promisify(execFile);
async function probe(binary,file){
 const {stdout}=await exec(binary,['-v','error','-show_streams','-show_format','-of','json',file],{maxBuffer:8*1024*1024});
 const data=JSON.parse(stdout),v=data.streams.find(s=>s.codec_type==='video');
 if(!v)throw Error('This file has no video stream.');
 let width=v.width,height=v.height;
 const rotation=v.side_data_list?.find(s=>s.rotation!==undefined)?.rotation||0;
 if(Math.abs(Math.round(rotation))%180===90)[width,height]=[height,width];
 const fraction=value=>{const [n,d=1]=String(value).split('/').map(Number);return n/d;};
 const fps=fraction(v.avg_frame_rate)||fraction(v.r_frame_rate);
 const duration=Number(data.format.duration||v.duration);
 if(width<height)throw Error('Choose a landscape video.');
 if(!Number.isFinite(duration)||duration<=0||!Number.isFinite(fps)||fps<=0||fps>240)throw Error('Unsupported duration or frame rate.');
 return {width,height,fps,duration,cropWidth:Math.floor(height*9/16/2)*2,cropHeight:Math.floor(height/2)*2};
}
function validate(data,meta){
 if(!Array.isArray(data.points)||!data.points.length||data.points.length>10000)throw Error('Add at least one tracking point.');
 const points=data.points.map(p=>({t:p.t,x:p.x})).sort((a,b)=>a.t-b.t);
 if(points.some((p,i)=>!Number.isFinite(p.t)||!Number.isFinite(p.x)||p.t<0||p.t>meta.duration||p.x<0||p.x>1||(i&&p.t-points[i-1].t<.000001)))throw Error('Invalid tracking points.');
 const trim=data.trim||{start:0,end:meta.duration};
 if(!Number.isFinite(trim.start)||!Number.isFinite(trim.end)||trim.start<0||trim.end>meta.duration||trim.end-trim.start<1/meta.fps)throw Error('Choose a valid trim range of at least one frame.');
 if(!['smooth','linear'].includes(data.mode)||!['720','1080'].includes(data.size))throw Error('Invalid export settings.');
 return {...data,points,trim:{...trim}};
}
function commands(points,width,mode){
 const f=n=>n.toFixed(9);
 const rows=[`0 crop@follow x '${f(points[0].x*width)}';`];
 for(let i=1;i<points.length;i++){
  const a=points[i-1],b=points[i],u=`((t-${f(a.t)})/${f(b.t-a.t)})`;
  const curve=mode==='linear'?u:`(${u}*${u}*(3-2*${u}))`;
  rows.push(`${f(a.t)} crop@follow x '${f(a.x*width)}+(${f((b.x-a.x)*width)})*${curve}';`);
 }
 const last=points.at(-1);rows.push(`${f(last.t)} crop@follow x '${f(last.x*width)}';`);
 return rows.join('\n');
}
async function render(binary,meta,data,destination,cache,job){
 const {points,trim,mode,size}=validate(data,meta),length=trim.end-trim.start;
 const dir=await fs.mkdtemp(path.join(cache,'render-'));
 // Render beside the destination, then atomically replace only after success.
 const partial=path.join(path.dirname(destination),`.danceframe-${randomUUID()}.mp4`);
 try{
  await fs.writeFile(path.join(dir,'motion.txt'),commands(points,meta.width-meta.cropWidth,mode));
  const vf=`setpts=PTS-STARTPTS,sendcmd=f=motion.txt,crop@follow=${meta.cropWidth}:${meta.cropHeight}:0:0:exact=1,trim=start=${trim.start}:end=${trim.end},setpts=PTS-STARTPTS,scale=${size==='1080'?'1080:1920':'720:1280'}:flags=lanczos,setsar=1`;
  const args=['-hide_banner','-y','-i',meta.path,'-map','0:v:0','-map','0:a:0?','-vf',vf,'-c:v','libx264','-preset','fast','-crf','18','-pix_fmt','yuv420p','-af',`atrim=start=${trim.start}:end=${trim.end},asetpts=PTS-STARTPTS`,'-t',String(length),'-c:a','aac','-b:a','192k','-movflags','+faststart','-progress','pipe:1','-nostats',partial];
  await new Promise((resolve,reject)=>{
   const child=spawn(binary,args,{cwd:dir,stdio:['ignore','pipe','pipe']});job.process=child;
   let stderr='',pending='';
   child.stderr.on('data',b=>stderr=(stderr+b.toString()).slice(-6000));
   child.stdout.on('data',b=>{pending+=b.toString();const lines=pending.split('\n');pending=lines.pop();for(const line of lines)if(line.startsWith('out_time_us='))job.progress=Math.min(.99,Math.max(0,Number(line.split('=')[1])/1e6/length)||0);});
   child.on('error',reject);child.on('close',code=>code===0&&!job.cancelled?resolve():reject(Error(job.cancelled?'Export cancelled.':stderr||'Export failed.')));
   if(job.cancelled)child.kill();
  });
  await fs.rename(partial,destination);
  Object.assign(job,{status:'done',progress:1,filename:path.basename(destination),path:destination});
 }catch(e){job.status=job.cancelled?'cancelled':'error';job.error=e.message;}
 finally{delete job.process;await fs.rm(partial,{force:true});await fs.rm(dir,{recursive:true,force:true});}
}
module.exports={probe,validate,commands,render};
