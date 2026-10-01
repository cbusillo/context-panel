import {spawn} from 'node:child_process';
import fs from 'node:fs';
import {pathToFileURL, fileURLToPath} from 'node:url';
import path from 'node:path';
import os from 'node:os';
const root=path.dirname(fileURLToPath(import.meta.url));
const scratch=fs.mkdtempSync(path.join(os.tmpdir(),'clear-skies-capture-'));
const chrome=spawn(process.env.CHROME_BIN || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',['--headless=new','--remote-debugging-port=0','--user-data-dir='+scratch,'--no-first-run','--no-default-browser-check','--disable-background-networking','--hide-scrollbars','about:blank'],{stdio:['ignore','ignore','pipe']});
let ws;try{
const url=await new Promise((resolve,reject)=>{let buffer='';chrome.stderr.on('data',chunk=>{buffer+=chunk.toString();const m=buffer.match(/DevTools listening on (ws:\/\/[^\s]+)/);if(m)resolve(m[1]);});chrome.on('exit',()=>reject(new Error('Chrome exited')));});
ws=new WebSocket(url);await new Promise(r=>ws.onopen=r);let id=0;const pending=new Map();ws.onmessage=e=>{const m=JSON.parse(e.data);if(m.id){const p=pending.get(m.id);pending.delete(m.id);m.error?p.reject(m.error):p.resolve(m.result);}};
const send=(method,params={},sessionId)=>new Promise((resolve,reject)=>{const n=++id;pending.set(n,{resolve,reject});ws.send(JSON.stringify({id:n,method,params,...sessionId?{sessionId}:{}}));});
const {targetId}=await send('Target.createTarget',{url:'about:blank'});const {sessionId}=await send('Target.attachToTarget',{targetId,flatten:true});
const call=(m,p)=>send(m,p,sessionId);await call('Page.enable');
const reports=[];
for(const file of fs.readdirSync(root).filter(f=>f.endsWith('.html'))){let html=fs.readFileSync(root+'/'+file,'utf8');let w=+html.match(/data-render-width="(\d+)"/)[1],h=+html.match(/data-render-height="(\d+)"/)[1];await call('Emulation.setDeviceMetricsOverride',{width:w,height:h,deviceScaleFactor:2,mobile:false});await call('Page.navigate',{url:pathToFileURL(root+'/'+file).href});await new Promise(r=>setTimeout(r,160));await call('Runtime.evaluate',{expression:'document.fonts.ready',awaitPromise:true});const result=await call('Runtime.evaluate',{expression:`JSON.stringify({viewport:[innerWidth,innerHeight],scroll:[document.documentElement.scrollWidth,document.documentElement.scrollHeight],outside:[...document.querySelectorAll('h1,h2,p,b,strong,.wfoot,.wdeadline,.event,.attention,footer')].filter(e=>{const r=e.getBoundingClientRect();return r.bottom>innerHeight+1||r.right>innerWidth+1}).map(e=>e.textContent.trim())})`,returnByValue:true});const {data}=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false});fs.writeFileSync(root+'/'+file.replace('.html','.png'),Buffer.from(data,'base64'));reports.push({file,...JSON.parse(result.result.value)});}
fs.writeFileSync(path.join(root,'render-checks.json'),JSON.stringify(reports,null,2)+'\n');console.log(JSON.stringify(reports,null,2));await send('Browser.close');
}finally{ws?.close();chrome.kill();await new Promise(r=>setTimeout(r,250));fs.rmSync(scratch,{recursive:true,force:true});}
