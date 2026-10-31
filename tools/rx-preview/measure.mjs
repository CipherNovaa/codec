// Preview the receiver's PARTY FACE in headless Chromium at the Bravia's canvas
// (1280x720 CSS px, dpr 1.5) with the Cast SDK stubbed and made-up rooms, one
// screenshot per state. Art is served from the hub's library (fetch intercept).
//   node rx_preview.mjs <receiver-url> <out-prefix> [poster-url] [logo-url] [backdrop-url]
import { spawn } from "node:child_process";
import { writeFileSync, mkdirSync, rmSync, readFileSync } from "node:fs";
const [URL_, OUT, POSTER = "", LOGO = "", BACKDROP = ""] = process.argv.slice(2);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const port = 9800 + Math.floor(Math.random() * 150);
const prof = `${OUT}-prof`; rmSync(prof, { recursive: true, force: true }); mkdirSync(prof, { recursive: true });
const ch = spawn("chromium", ["--headless=new", `--remote-debugging-port=${port}`, `--user-data-dir=${prof}`,
  "--no-first-run", "--mute-audio", "--ignore-certificate-errors", "about:blank"], { stdio: "ignore" });
process.on("exit", () => ch.kill());
let ok; for (let i = 0; i < 40 && !ok; i++) { try { ok = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json(); } catch { await sleep(250); } }
const pages = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(pages.find((p) => p.type === "page").webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener("open", r, { once: true }));
let seq = 0; const pending = new Map(); const handlers = {};
ws.addEventListener("message", (e) => { const m = JSON.parse(e.data);
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); }
  else if (m.method && handlers[m.method]) handlers[m.method](m.params); });
const cdp = (method, params = {}) => new Promise((r) => { const id = ++seq; pending.set(id, r); ws.send(JSON.stringify({ id, method, params })); });
const js = async (expr) => { const r = await cdp("Runtime.evaluate", { expression: expr, awaitPromise: true, returnByValue: true });
  if (r.result?.exceptionDetails) console.log("JS ERR", r.result.exceptionDetails.text, r.result.exceptionDetails.exception?.description?.slice(0, 300));
  return r.result?.result?.value; };
const shot = async (name) => { const r = await cdp("Page.captureScreenshot", { format: "png" }); writeFileSync(`${OUT}_${name}.png`, Buffer.from(r.result.data, "base64")); console.log("shot", name); };

// ── the Cast SDK, stubbed: every property is a callable proxy; the few readers
// the face uses answer from window.__pv (the preview's player facts)
const STUB = `
(function(){
  var PS={PLAYING:'PLAYING',PAUSED:'PAUSED',BUFFERING:'BUFFERING',IDLE:'IDLE'};
  window.__pv={cur:0,dur:0,ps:'IDLE',h:0,w:0,loaded:false,stats:{},vol:0.6,muted:false};
  function leaf(path){
    var f=function(){};
    return new Proxy(f,{
      get:function(t,k){ if(k===Symbol.toPrimitive) return function(){return path;}; if(typeof k!=='string') return undefined;
        if(k==='then') return undefined;
        var p=path+'.'+k;
        if(k==='PlayerState') return PS;
        if(k==='prototype') return f.prototype;
        return leaf(p); },
      apply:function(t,th,args){
        var k=path.slice(path.lastIndexOf('.')+1);
        switch(k){
          case 'getInstance': return leaf('ctx');
          case 'getPlayerManager': return leaf('pm');
          case 'getCurrentTimeSec': return window.__pv.cur;
          case 'getDurationSec': return window.__pv.dur;
          case 'getPlayerState': return window.__pv.ps;
          case 'getMediaInformation': return window.__pv.loaded?{contentId:'x',customData:{}}:null;
          case 'getSystemVolume': return {level:window.__pv.vol, muted:window.__pv.muted};
          case 'getTextTracksManager': return {getActiveIds:function(){return [7];}, getTracks:function(){return [{trackId:7,language:'en'}];}};
          case 'getStats': return Object.assign({width:window.__pv.w,height:window.__pv.h,droppedFrames:0,decodedFrames:0,bufferingTime:0},window.__pv.stats);
          case 'getPlaybackConfig': return {};
          case 'canDisplayType': return true;
          case 'getDeviceCapabilities': return {};
          case 'getApplicationData': return {};
          case 'getSenders': return [];
          case 'addEventListener': case 'setMessageInterceptor': case 'start': case 'setPlaybackConfig':
          case 'addCustomMessageListener': case 'setLoggerLevel': case 'pause': case 'play': case 'seek': case 'stop': case 'load':
            return undefined;
        }
        return leaf(path+'()');
      },
      construct:function(){ return {}; }
    });
  }
  window.cast={framework:leaf('cast.framework')};
})();`;

await cdp("Page.enable"); await cdp("Runtime.enable"); await cdp("Fetch.enable", { patterns: [{ urlPattern: "*" }] });
const b64 = async (u) => Buffer.from(await (await fetch(u)).arrayBuffer()).toString("base64");
const artCache = {};
handlers["Fetch.requestPaused"] = async ({ requestId, request }) => {
  const u = request.url;
  try {
    if (u.includes("cast_receiver_framework")) {
      await cdp("Fetch.fulfillRequest", { requestId, responseCode: 200, responseHeaders: [{ name: "Content-Type", value: "application/javascript" }], body: Buffer.from(STUB).toString("base64") }); return; }
    const m = u.match(/\/art\?which=(poster|logo|backdrop)/);
    if (m) {
      const src = { poster: POSTER, logo: LOGO, backdrop: BACKDROP }[m[1]];
      if (!src) { await cdp("Fetch.failRequest", { requestId, errorReason: "Failed" }); return; }
      artCache[src] = artCache[src] || await b64(src);
      await cdp("Fetch.fulfillRequest", { requestId, responseCode: 200, responseHeaders: [{ name: "Content-Type", value: src.endsWith(".png") ? "image/png" : "image/jpeg" }], body: artCache[src] }); return; }
    if (u.includes("/p/") && (u.includes("/state") || u.includes("/party/"))) { await cdp("Fetch.failRequest", { requestId, errorReason: "Failed" }); return; }
    await cdp("Fetch.continueRequest", { requestId });
  } catch (e) { try { await cdp("Fetch.continueRequest", { requestId }); } catch {} }
};
await cdp("Emulation.setDeviceMetricsOverride", { width: 1280, height: 720, deviceScaleFactor: 1.5, mobile: false });
await cdp("Page.navigate", { url: URL_ }); await sleep(2500);
const ROOM = [{ id: "a", me: true, name: "Living Room TV", rtt: 12, w: true, st: "seated", tv: true },{ id: "b", name: "Riley", rtt: 41, w: true, st: "seated" }];
const MEDIA = { title: "Police Story", year: "1985", dur: 6032, rating: 7.56, genres: "Action / Crime / Comedy", director: "Jackie Chan", revenue: 18724000, budget: 0, audio: "AAC 2.0", kind: "file", hasPoster: !!POSTER, hasLogo: !!LOGO, hasBackdrop: !!BACKDROP };
const st = JSON.stringify({ active: true, seq: 1, room: ROOM, pos: 905, paused: true, rate: 1, epoch_ms: 0, server_now_ms: 0, room_lag_ms: 300, lag_who: "", waiting_for: [], loading: false, load_seq: 0, film_end: false, next: "", chat: [], chat_seq: 0, media: MEDIA, tv: {dv:true,gen:1,warm:0,audio:'AAC 5.1'} });
await js(`pfaceOn({stateUrl:'https://x/p/tok/state'}); Object.assign(window.__pv,{cur:905,dur:6032,ps:'PAUSED',h:2160,w:3840,loaded:true}); paintParty(${st}); PARTYDV=true; paintLane(); paintMeta(); pdCardAt=Date.now()-3000; pdockRender(); 'ok'`);
await sleep(1200);
const out = await js(`(function(){
  var r={};
  // ink vs em box, per face and size (caps + digits, what the dock sets)
  var c=document.createElement('canvas').getContext('2d'); r.fonts={};
  [['mgshud',16],['mgshud',20],['mgshud',22],['mgscodec',13],['mgscodec',16],['mgscodec',34],['depmono',16]].forEach(function(p){
    c.font=p[1]+'px '+p[0]; var m=c.measureText('ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789');
    var dy=((m.actualBoundingBoxAscent-m.actualBoundingBoxDescent)-(m.fontBoundingBoxAscent-m.fontBoundingBoxDescent))/2;
    r.fonts[p[0]+'@'+p[1]]={fA:+m.fontBoundingBoxAscent.toFixed(2),fD:+m.fontBoundingBoxDescent.toFixed(2),iA:+m.actualBoundingBoxAscent.toFixed(2),iD:+m.actualBoundingBoxDescent.toFixed(2),inkAboveEmCentre:+dy.toFixed(2)};
  });
  function rc(sel){ var e=document.querySelector(sel); if(!e) return null; var b=e.getBoundingClientRect(); return {t:+b.top.toFixed(1),h:+b.height.toFixed(1),cy:+(b.top+b.height/2).toFixed(1),l:+b.left.toFixed(1),w:+b.width.toFixed(1)}; }
  r.rows={glyph:rc('#pdglyph'),logo:rc('#pdlogo'),title:rc('#pdtitle'),meta:rc('#pdmeta'),vid:rc('#pdvid'),vol:rc('#pdvol'),volseg:rc('#pdvol .seg'),voln:rc('#pdvoln'),
          elapsedL:rc('.pdbot .pdl'),elapsedV:rc('#pdel'),roster:rc('#proster'),rosterName:rc('#proster .r span:last-child'),rosterDot:rc('#proster .d'),rem:rc('#pdrem'),
          badge:rc('#pcmeta .mbadge'),badgeLab:rc('#pcmeta .mblabel'),badgeBefore:null,
          cardBrand:rc('#pcbrand'),cardLogo:rc('#pclogo'),cardStars:rc('#pcstars'),cardDir:rc('#pcdir'),cardDirB:rc('#pcdir b'),cardMoney:rc('#pcmoney'),cardMoneyB:rc('#pcmoney b'),cardNote:rc('#pcnote'),poster:rc('#pcpw'),col:rc('#pctxt')};
  r.t1=getComputedStyle(document.documentElement).getPropertyValue('--t1'); r.t2=getComputedStyle(document.documentElement).getPropertyValue('--t2');
  return JSON.stringify(r);
})()`);
console.log(out);
ws.close(); ch.kill(); process.exit(0);
