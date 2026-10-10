const {test}=require('node:test');const assert=require('node:assert/strict');
const fs=require('node:fs/promises'),os=require('node:os'),path=require('node:path');
const {execFile}=require('node:child_process');const exec=require('node:util').promisify(execFile);
const {probe,validate,render}=require('../video.cjs');
const ffmpeg=path.join(__dirname,'../../build-resources/binaries/ffmpeg'),ffprobe=path.join(__dirname,'../../build-resources/binaries/ffprobe');
test('reject invalid tracking and trim input',()=>{
 const meta={duration:2,fps:24};const good={points:[{t:0,x:.5}],trim:{start:0,end:2},mode:'smooth',size:'720'};
 for(const bad of [{points:[]},{points:[{t:0,x:NaN}]},{points:[{t:1,x:0},{t:1,x:1}]},{trim:{start:1,end:.5}},{trim:{start:0,end:Infinity}},{mode:'bad'}])assert.throws(()=>validate({...good,...bad},meta));
});
test('bundled encoder preserves motion, trim, audio, and output size',async()=>{
 const dir=await fs.mkdtemp(path.join(os.tmpdir(),'danceframe-test-'));
 try{
  const source=path.join(dir,'source.mp4');
  await exec(ffmpeg,['-v','error','-f','lavfi','-i',"nullsrc=s=640x360:r=24:d=2,geq=lum='16+200*X/W':cb=128:cr=128",'-f','lavfi','-i','sine=frequency=440:duration=2','-c:v','libx264','-crf','12','-pix_fmt','yuv420p','-c:a','aac','-shortest',source]);
  const meta={...await probe(ffprobe,source),path:source};
  for(const mode of ['smooth','linear']){
   const destination=path.join(dir,mode+'.mp4'),job={status:'running',progress:0};
   await render(ffmpeg,meta,{points:[{t:.25,x:0},{t:1.75,x:1}],trim:{start:.5,end:1.5},mode,size:'720'},destination,dir,job);
   assert.equal(job.status,'done',job.error);
   const data=JSON.parse((await exec(ffprobe,['-v','error','-show_streams','-show_format','-of','json',destination])).stdout);
   assert.equal(data.streams[0].width,720);assert.equal(data.streams[0].height,1280);assert.ok(data.streams.some(s=>s.codec_type==='audio'));assert.ok(Math.abs(Number(data.format.duration)-1)<.1);
   for(const local of [0,.25,.5,.875]){
    const t=local+.5;let u=Math.max(0,Math.min(1,(t-.25)/1.5));if(mode==='smooth')u=u*u*(3-2*u);
    const x=Math.floor(u*(640-meta.cropWidth));
    const mean=async(file,time,filter)=>(await exec(ffmpeg,['-v','error','-i',file,'-ss',String(time),'-frames:v','1','-vf',filter,'-pix_fmt','gray','-f','rawvideo','pipe:1'],{encoding:'buffer'})).stdout[0];
    const expected=await mean(source,t,`crop=${meta.cropWidth}:${meta.cropHeight}:${x}:0:exact=1,scale=720:1280:flags=lanczos,scale=1:1`);
    const actual=await mean(destination,local,'scale=1:1');assert.ok(Math.abs(actual-expected)<=3,`${mode} ${local}: ${actual} vs ${expected}`);
   }
  }
  const existing=path.join(dir,'existing.mp4');await fs.writeFile(existing,'KEEP');
  const job={status:'running',progress:0,cancelled:true};
  await render(ffmpeg,meta,{points:[{t:0,x:.5}],mode:'smooth',size:'720'},existing,dir,job);
  assert.equal(job.status,'cancelled');assert.equal(await fs.readFile(existing,'utf8'),'KEEP');
 }finally{await fs.rm(dir,{recursive:true,force:true});}
});
