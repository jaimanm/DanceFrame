// Bundle the tested local FFmpeg installation and relocate its non-system dylibs.
const fs=require('node:fs/promises'),path=require('node:path');
const exec=require('node:util').promisify(require('node:child_process').execFile);
const env={...process.env,DEVELOPER_DIR:'/Library/Developer/CommandLineTools'};
async function bundle(out){
 await fs.mkdir(out,{recursive:true});
 const seen=new Map(),names=new Map();
 async function visit(source){
  const real=await fs.realpath(source);if(seen.has(real))return seen.get(real).name;
  const name=path.basename(source);
  if(names.has(name)&&names.get(name)!==real)throw Error('Conflicting library: '+name);
  names.set(name,real);const item={name,source:real,deps:[]};seen.set(real,item);
  const {stdout}=await exec('/usr/bin/otool',['-L',real],{env});
  const dependencies=stdout.split('\n').slice(1).map(line=>line.trim().split(' (')[0]).filter(Boolean);
  for(const dep of dependencies){
   if(dep.startsWith('/System/')||dep.startsWith('/usr/lib/'))continue;
   let resolved=dep;
   if(dep.startsWith('@loader_path/'))resolved=path.join(path.dirname(real),dep.slice(13));
   if(dep.startsWith('@rpath/')){
    const load=(await exec('/usr/bin/otool',['-l',real],{env})).stdout;
    const candidates=[...load.matchAll(/cmd LC_RPATH\n\s*cmdsize \d+\n\s*path (.+?) \(offset/g)].map(m=>m[1].replace('@loader_path',path.dirname(real)));
    resolved=null;
    for(const base of candidates){const candidate=path.join(base,dep.slice(7));try{await fs.access(candidate);resolved=candidate;break;}catch{}}
    if(!resolved)throw Error('Cannot resolve '+dep+' in '+real);
   }
   if(await fs.realpath(resolved)===real)continue;
   item.deps.push([dep,await visit(resolved)]);
  }
  return name;
 }
 await visit(process.env.DANCEFRAME_FFMPEG||'/opt/homebrew/bin/ffmpeg');
 await visit(process.env.DANCEFRAME_FFPROBE||'/opt/homebrew/bin/ffprobe');
 for(const item of seen.values()){
  const dest=path.join(out,item.name);await fs.copyFile(item.source,dest);await fs.chmod(dest,0o755);
  const args=[];if(item.name.endsWith('.dylib'))args.push('-id','@loader_path/'+item.name);
  for(const [original,name] of item.deps)args.push('-change',original,'@loader_path/'+name);
  if(args.length)await exec('/usr/bin/install_name_tool',[...args,dest],{env});
  await exec('/usr/bin/codesign',['--force','--sign','-',dest],{env});
 }
 await fs.writeFile(path.join(out,'SOURCES.txt'),'Bundled from the local Homebrew FFmpeg installation.\nFFmpeg: https://ffmpeg.org/ (GPL build with libx264)\nHomebrew formula and dependency source URLs: https://github.com/Homebrew/homebrew-core/blob/master/Formula/f/ffmpeg.rb\nBuild is for personal local use; review licenses before redistribution.\n');
 console.log(`Bundled FFmpeg and ${seen.size-2} local libraries.`);
}
module.exports=bundle;
if(require.main===module)bundle(process.argv[2]).catch(e=>{console.error(e);process.exit(1);});
