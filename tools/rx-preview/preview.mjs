// Preview the Cast receiver's FACE (party and solo states) in headless Chromium at the Bravia's canvas
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
console.log("face present:", await js("!!document.getElementById('pdock') && typeof paintParty==='function'"));

// a backdrop stands in for the film frame, so legibility over a picture is judged too
// (no stand-in frame: the paused card's hero is the thing being judged)

const ROOM = [
  { id: "a", me: true, name: "Living Room TV", rtt: 12, w: true, st: "seated", tv: true },
  { id: "b", name: "Riley", rtt: 41, w: true, st: "seated" },
  { id: "c", name: "Sam", rtt: 190, w: true, st: "joining" },
  { id: "d", name: "Jordan", rtt: -1, w: false, st: "card" },
];
const PM = process.env.PV_META ? JSON.parse(process.env.PV_META) : {};
const MEDIA = Object.assign({ title: "Police Story", year: "1985", dur: 6032, rating: 7.56, genres: "Action / Crime / Comedy",
  director: "Jackie Chan", revenue: 18724000, budget: 0, audio: "AAC 2.0", kind: "file" }, PM,
  { hasPoster: !!POSTER, hasLogo: !!LOGO, hasBackdrop: !!BACKDROP });
const st = (o) => JSON.stringify(Object.assign({ active: true, seq: 1, room: ROOM, pos: 900, paused: false, rate: 1,
  epoch_ms: 0, server_now_ms: 0, room_lag_ms: 300, lag_who: "", waiting_for: [], loading: false, load_seq: 0,
  film_end: false, next: "", chat: [], chat_seq: 0, media: MEDIA, tv: {dv:true,gen:1,warm:0,audio:'AAC 5.1'} }, o));
const pv = (o) => js(`Object.assign(window.__pv, ${JSON.stringify(o)}); 'ok'`);
const paint = async (o) => { await js(`paintParty(${st(o)}); pdockRender(); 'ok'`); await sleep(650); };

await js(`pfaceOn({stateUrl:'https://codec-party.example/p/tok/state'}); 'ok'`);
await sleep(300); await shot("00_joining");
// 1. joined, the room paused at the start: dock, then the card
await pv({ cur: 0, dur: 6032, ps: "PAUSED", h: 2160, w: 3840, loaded: true });
await paint({ pos: 0, paused: true }); await js("PARTYDV=true; paintLane(); pdCardAt=Date.now()-3000; pdockRender(); 'ok'"); await sleep(700);
await shot("01_join_paused_card");
// 2. playing, nothing up
await pv({ cur: 905, ps: "PLAYING" }); await js("pdUntil=0; pdCardAt=0; 'ok'"); await paint({ pos: 900, paused: false }); await sleep(2600); await shot("02_playing_bare");
// 3. the dock up (transport activity) with the lane badges
await js("pdockOn(5000); pdockRender(); paintMeta(); 'ok'"); await sleep(500); await shot("03_playing_dock");
// 3b. muted
await pv({ muted: true }); await js("paintMeta(); 'ok'"); await sleep(200); await shot("03b_muted"); await pv({ muted: false });
// 4. chat lines arriving
await paint({ chat: [{ i: 1, who: "Riley", text: "this looks unreal on the tv", kind: "say" }, { i: 2, who: "Sam", text: "that sound mix", kind: "say" }, { i: 3, who: "Riley", text: "🔥", kind: "react" }] });
await js("pdUntil=0; pdockRender(); 'ok'"); await sleep(400); await shot("04_chat_feed");
// 5. paused mid-film: dock + the card
await pv({ cur: 905, ps: "PAUSED" }); await paint({ pos: 905, paused: true }); await js("pdCardAt=Date.now()-3000; pdockRender(); 'ok'"); await sleep(700); await shot("05_paused_card");
// 6. buffering after a seek
await pv({ cur: 1500, ps: "BUFFERING" }); await paint({ pos: 1500, paused: false }); await js("pdCardAt=0; pdockRender(); 'ok'"); await sleep(400); await shot("06_buffering");
// 7. a film change: the hold
await pv({ cur: 0, ps: "PAUSED" }); await paint({ pos: 0, paused: true, loading: true, load_seq: 2, media: Object.assign({}, MEDIA, { title: "Seinfeld — The Seinfeld Chronicles", hasLogo: false, hasPoster: false }) }); await shot("07_change_hold");
// 8. the end of the queue
await pv({ cur: 6031, ps: "IDLE" }); await paint({ pos: 6031, paused: false, film_end: true }); await shot("08_end");
// 9. a real error
await paint({ pos: 6000, paused: false }); await js("castFailed=true; perror('Error 310'); 'ok'"); await sleep(400); await shot("09_error");
// 10. the party closes
await js("castFailed=false; partyOver(); 'ok'"); await sleep(400); await shot("10_party_over");
// ── SOLO: the same face from the app's customData (art straight off the hub)
const SCD = { streamUrl: "http://x/hls/pl?src=police&dv=1", dash: true, hdr: true, dv: true, fullDur: 6032,
  poster: POSTER, logo: LOGO, backdrop: BACKDROP, year: MEDIA.year, rating: MEDIA.rating, dir: MEDIA.director,
  gen: MEDIA.genres, revenueN: MEDIA.revenue, budgetN: MEDIA.budget, flags: ["4K","DV","5.1"], ach: 6, audio: "DTS-HD MA 5.1" };
await pv({ cur: 0, dur: 0, ps: "IDLE", h: 0, w: 0, loaded: false });
await js(`FULL_DUR=6032; DV_LANE=true; sfaceOn(${JSON.stringify(SCD)}, "Police Story", "application/dash+xml", false); pdockRender(); 'ok'`);
await sleep(600); await shot("11_solo_loading");
await pv({ cur: 905, dur: 6032, ps: "PLAYING", h: 2160, w: 3840, loaded: true });
await js("soloTick(); pdockRender(); paintMeta(); 'ok'"); await sleep(600); await shot("12_solo_first_play");
await pv({ cur: 905, ps: "PAUSED" });
await js("pdCardAt=Date.now()-3000; pdockRender(); paintMeta(); 'ok'"); await sleep(900); await shot("13_solo_paused_card");
await js("showToast('Subtitles · English', 0, false, false); 'ok'"); await sleep(300); await shot("14_solo_toast");
ws.close(); ch.kill(); process.exit(0);
