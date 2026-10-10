'use strict';
const fs=require('node:fs/promises');
const path=require('node:path');
(async()=>{
 const {packager}=await import('@electron/packager');
 const root=path.join(__dirname,'..');
 const binaries=path.join(root,'build-resources','binaries');await fs.mkdir(binaries,{recursive:true});
 await require('./bundle-ffmpeg.cjs')(binaries);
 const results=await packager({dir:root,out:path.join(root,'dist'),name:'DanceFrame',appBundleId:'com.danceframe.desktop',appVersion:'1.0.0',platform:'darwin',arch:process.arch,asar:true,overwrite:true,prune:false,ignore:[/^\/node_modules/,/^\/dist/,/^\/build-resources/,/^\/\.git/,/^\/desktop\/test/,/^\/WEB-README/],extraResource:[binaries]});
 for(const result of results)await require('node:util').promisify(require('node:child_process').execFile)('/usr/bin/codesign',['--force','--deep','--sign','-',path.join(result,'DanceFrame.app')]);
 console.log(results.join('\n'));
})().catch(e=>{console.error(e);process.exit(1);});
