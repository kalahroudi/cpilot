// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The page a paired phone opens. One file, no build step and no library. Text from a model or a repository is only ever inserted as DOM text nodes
/// (the Markdown renderer builds elements itself and allows only http and https links); the only `innerHTML` is the fixed icon set below.
enum RemotePage {
    static let manifest = ##"{"name":"CPilot","short_name":"CPilot","start_url":"/","display":"standalone","background_color":"#111114","theme_color":"#111114"}"##

    static let html = #"""
    <!doctype html>
    <html lang="en"><head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
    <meta name="apple-mobile-web-app-title" content="CPilot">
    <meta name="theme-color" content="#111114">
    <link rel="manifest" href="/manifest.json">
    <title>CPilot</title>
    <style>
    :root{--bg:#f2f2f5;--card:#fff;--ink:#16161a;--dim:#6b6b76;--line:#e4e4ea;--soft:#ececf1;--accent:#2b7fff;--accent-ink:#fff;--ok:#27a35a;--warn:#c97a00;--bad:#d6382f;--shadow:0 1px 2px rgba(0,0,0,.05)}
    @media(prefers-color-scheme:dark){:root{--bg:#0e0e11;--card:#18181d;--ink:#f1f1f4;--dim:#9494a0;--line:#2a2a31;--soft:#222228;--accent:#4d95ff;--ok:#43c46f;--warn:#f2a73a;--bad:#ff6d64;--shadow:none}}
    *{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
    html,body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.45 -apple-system,BlinkMacSystemFont,system-ui,sans-serif;-webkit-text-size-adjust:100%}
    body{max-width:680px;margin:0 auto;padding:0 16px calc(84px + env(safe-area-inset-bottom))}
    body.insession{padding-bottom:calc(88px + env(safe-area-inset-bottom))}
    .ic{display:inline-flex;width:20px;height:20px;flex:none}.ic svg{width:100%;height:100%}
    button{font:inherit;color:inherit;border:0;background:none;padding:0;cursor:pointer}
    /* header */
    .top{position:sticky;top:0;z-index:5;background:var(--bg);padding:calc(12px + env(safe-area-inset-top)) 0 10px;display:flex;align-items:center;gap:10px}
    .top h1{font-size:22px;font-weight:700;letter-spacing:-.02em;margin:0;flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    .live{display:inline-flex;align-items:center;gap:6px;font-size:12px;color:var(--dim);background:var(--card);border:1px solid var(--line);border-radius:99px;padding:4px 10px}
    .live i{width:7px;height:7px;border-radius:50%;background:var(--bad)}.live.on i{background:var(--ok)}
    /* cards, rows */
    .card{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:14px;margin:0 0 12px;box-shadow:var(--shadow)}
    .card.amber{border-color:color-mix(in srgb,var(--warn) 55%,var(--line));background:color-mix(in srgb,var(--warn) 7%,var(--card))}
    .row{display:flex;align-items:center;gap:12px}.grow{flex:1;min-width:0}.gap{height:10px}
    .t{font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.s{color:var(--dim);font-size:13px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    .wrap{white-space:pre-wrap;word-break:break-word}
    .sec{display:flex;align-items:center;gap:8px;font-size:12px;font-weight:600;letter-spacing:.07em;text-transform:uppercase;color:var(--dim);margin:20px 4px 8px}
    .sec b{background:var(--soft);color:var(--ink);border-radius:99px;padding:0 7px;font-size:11px;letter-spacing:0}
    .srow{display:flex;align-items:center;gap:12px;background:var(--card);border:1px solid var(--line);border-radius:16px;padding:12px 14px;margin:0 0 8px;box-shadow:var(--shadow);cursor:pointer}
    .srow:active{background:var(--soft)}
    .badge{width:36px;height:36px;border-radius:11px;display:grid;place-items:center;background:var(--soft);color:var(--dim);flex:none}
    .badge.working{color:var(--accent);background:color-mix(in srgb,var(--accent) 14%,transparent)}.badge.approval{color:var(--warn);background:color-mix(in srgb,var(--warn) 16%,transparent)}
    .badge.failed{color:var(--bad);background:color-mix(in srgb,var(--bad) 14%,transparent)}.badge.idle.chief{color:var(--accent)}
    .ago{font-size:12px;color:var(--dim)}.chev{color:var(--dim);opacity:.6}
    .spin{animation:spin 1s linear infinite}@keyframes spin{to{transform:rotate(360deg)}}
    .chips{display:flex;gap:8px;flex-wrap:wrap;margin:0 0 6px}
    .chip{display:inline-flex;align-items:center;gap:6px;border-radius:99px;padding:6px 12px;font-size:13px;font-weight:500;background:var(--card);border:1px solid var(--line)}
    .chip.warn{color:var(--warn);border-color:color-mix(in srgb,var(--warn) 50%,var(--line))}.chip.acc{color:var(--accent)}
    .empty{text-align:center;color:var(--dim);padding:44px 20px}.empty .ic{width:40px;height:40px;opacity:.5;margin-bottom:10px}.empty b{display:block;color:var(--ink);font-size:17px;margin-bottom:4px}
    /* buttons, fields */
    .btn{display:inline-flex;align-items:center;justify-content:center;gap:8px;min-height:46px;padding:0 18px;border-radius:13px;font-weight:600;background:var(--soft);color:var(--ink)}
    .btn.primary{background:var(--accent);color:var(--accent-ink)}.btn.danger{color:var(--bad)}.btn.block{width:100%}.btn:disabled{opacity:.45}.btn:active{filter:brightness(.92)}
    .btn.sm{min-height:38px;padding:0 14px;border-radius:11px;font-size:15px}
    .iconbtn{width:40px;height:40px;border-radius:50%;display:grid;place-items:center;background:var(--card);border:1px solid var(--line)}.iconbtn.danger{color:var(--bad)}
    label{display:block;font-size:13px;font-weight:600;color:var(--dim);margin:14px 0 6px}label:first-child{margin-top:0}
    select,textarea,input[type=text],input:not([type]){width:100%;font:inherit;color:var(--ink);background:var(--bg);border:1px solid var(--line);border-radius:12px;padding:12px;outline:none}
    select:focus,textarea:focus,input:focus{border-color:var(--accent)}textarea{min-height:120px;resize:vertical}
    .seg{display:flex;background:var(--soft);border-radius:12px;padding:3px;gap:3px}.seg button{flex:1;min-height:38px;border-radius:9px;font-size:14px;font-weight:600;color:var(--dim)}.seg button.on{background:var(--card);color:var(--ink);box-shadow:0 1px 2px rgba(0,0,0,.12)}
    .hint{font-size:13px;color:var(--dim);margin-top:10px}
    .acts{display:flex;gap:10px;margin-top:12px}.acts .btn{flex:1}
    /* tab bar */
    nav{position:fixed;left:0;right:0;bottom:0;z-index:6;background:color-mix(in srgb,var(--card) 88%,transparent);backdrop-filter:saturate(1.6) blur(14px);-webkit-backdrop-filter:saturate(1.6) blur(14px);border-top:1px solid var(--line);padding:6px 8px calc(6px + env(safe-area-inset-bottom));display:flex;justify-content:center}
    nav .in{display:flex;width:100%;max-width:680px}nav button{flex:1;display:flex;flex-direction:column;align-items:center;gap:2px;font-size:11px;font-weight:600;color:var(--dim);padding:6px 0;position:relative}
    nav button.on{color:var(--accent)}nav button .n{position:absolute;top:0;left:calc(50% + 6px);min-width:17px;height:17px;border-radius:9px;background:var(--bad);color:#fff;font-size:11px;display:grid;place-items:center;padding:0 4px}
    body.insession nav,nav:empty{display:none}
    /* session */
    .sbar{position:sticky;top:0;z-index:5;background:var(--bg);padding:calc(10px + env(safe-area-inset-top)) 0 8px;display:flex;align-items:center;gap:10px}
    .stat{font-size:12px;font-weight:600;border-radius:99px;padding:3px 10px;background:var(--soft);color:var(--dim);white-space:nowrap}
    .stat.working{color:var(--accent);background:color-mix(in srgb,var(--accent) 14%,transparent)}.stat.approval{color:var(--warn);background:color-mix(in srgb,var(--warn) 16%,transparent)}.stat.failed{color:var(--bad);background:color-mix(in srgb,var(--bad) 14%,transparent)}
    .bubble{background:var(--accent);color:var(--accent-ink);border-radius:18px 18px 4px 18px;padding:9px 14px;margin:14px 0 14px 18%;white-space:pre-wrap;word-break:break-word;width:fit-content;max-width:82%;margin-left:auto}
    .ans{margin:10px 0}.tool{display:flex;align-items:center;gap:8px;font-size:13px;color:var(--dim);background:var(--card);border:1px solid var(--line);border-radius:10px;padding:6px 10px;margin:5px 0}
    .tool .tx{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.tool.ok .ic:last-child{color:var(--ok)}.tool.bad .ic:last-child{color:var(--bad)}
    .note{text-align:center;font-size:12px;color:var(--dim);margin:10px 0}.err{border:1px solid color-mix(in srgb,var(--bad) 50%,var(--line));color:var(--bad);border-radius:12px;padding:8px 12px;margin:8px 0;font-size:14px}
    .dots{display:inline-flex;gap:4px;padding:8px 2px}.dots i{width:7px;height:7px;border-radius:50%;background:var(--dim);animation:blink 1.2s infinite both}.dots i:nth-child(2){animation-delay:.2s}.dots i:nth-child(3){animation-delay:.4s}
    @keyframes blink{0%,80%,100%{opacity:.25}40%{opacity:1}}
    .comp{position:fixed;left:0;right:0;bottom:0;z-index:6;background:color-mix(in srgb,var(--bg) 92%,transparent);backdrop-filter:blur(14px);-webkit-backdrop-filter:blur(14px);padding:8px 12px calc(10px + env(safe-area-inset-bottom))}
    .comp .in{display:flex;gap:8px;align-items:flex-end;max-width:680px;margin:0 auto}
    .comp textarea{min-height:44px;max-height:160px;border-radius:22px;padding:11px 16px;resize:none;background:var(--card);line-height:1.35}
    .send{width:44px;height:44px;border-radius:50%;background:var(--accent);color:#fff;display:grid;place-items:center;flex:none}.send:disabled{background:var(--soft);color:var(--dim)}
    /* markdown */
    .md{word-break:break-word}.md>*:first-child{margin-top:0}.md>*:last-child{margin-bottom:0}
    .md p{margin:.55em 0}.md ul,.md ol{margin:.5em 0;padding-left:1.4em}.md li{margin:.2em 0}.md li>ul,.md li>ol{margin:.2em 0}
    .md .mh{font-weight:700;margin:1em 0 .35em;line-height:1.25}.md .mh1{font-size:1.3em}.md .mh2{font-size:1.18em}.md .mh3{font-size:1.07em}
    .md code{font:.88em ui-monospace,SFMono-Regular,Menlo,monospace;background:var(--soft);border-radius:6px;padding:.12em .38em}
    .md pre{background:var(--soft);border:1px solid var(--line);border-radius:12px;padding:10px 12px;overflow-x:auto;margin:.6em 0}.md pre code{background:none;padding:0;font-size:.84em;white-space:pre}
    .md blockquote{margin:.6em 0;padding:.1em 0 .1em 12px;border-left:3px solid var(--line);color:var(--dim)}
    .md a{color:var(--accent);text-decoration:none;border-bottom:1px solid color-mix(in srgb,var(--accent) 40%,transparent)}.md hr{border:0;border-top:1px solid var(--line);margin:1em 0}
    .md .tw{overflow-x:auto;margin:.6em 0}.md table{border-collapse:collapse;font-size:.92em}.md th,.md td{border:1px solid var(--line);padding:5px 10px;text-align:left}.md th{background:var(--soft)}
    .toast{position:fixed;left:16px;right:16px;top:calc(10px + env(safe-area-inset-top));z-index:20;max-width:560px;margin:0 auto;background:var(--ink);color:var(--bg);border-radius:14px;padding:12px 16px;font-size:14px;box-shadow:0 8px 24px rgba(0,0,0,.25)}
    .hero{text-align:center;padding:48px 0 20px}.hero .logo{width:64px;height:64px;border-radius:18px;background:var(--accent);color:#fff;display:grid;place-items:center;margin:0 auto 14px}.hero .logo .ic{width:34px;height:34px}.hero h1{margin:0 0 6px;font-size:26px}
    </style></head><body>
    <div id="app"></div><nav id="nav"></nav>
    <script>
    "use strict";
    const $=s=>document.querySelector(s);
    const P={
     list:'<line x1="8" y1="6" x2="21" y2="6"/><line x1="8" y1="12" x2="21" y2="12"/><line x1="8" y1="18" x2="21" y2="18"/><circle cx="3.5" cy="6" r="1"/><circle cx="3.5" cy="12" r="1"/><circle cx="3.5" cy="18" r="1"/>',
     compass:'<circle cx="12" cy="12" r="10"/><polygon points="16.24 7.76 14.12 14.12 7.76 16.24 9.88 9.88 16.24 7.76"/>',
     plus:'<line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/>',
     phone:'<rect x="5" y="2" width="14" height="20" rx="2"/><line x1="12" y1="18" x2="12.01" y2="18"/>',
     back:'<polyline points="15 18 9 12 15 6"/>',next:'<polyline points="9 18 15 12 9 6"/>',
     up:'<line x1="12" y1="19" x2="12" y2="5"/><polyline points="5 12 12 5 19 12"/>',
     stop:'<rect x="6" y="6" width="12" height="12" rx="2.5"/>',
     check:'<polyline points="20 6 9 17 4 12"/>',x:'<line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/>',
     shield:'<path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/>',
     tool:'<path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z"/>',
     alert:'<path d="M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"/><line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/>',
     bolt:'<polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"/>',
     spinner:'<path d="M21 12a9 9 0 1 1-6.2-8.55"/>',
     out:'<path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><polyline points="16 17 21 12 16 7"/><line x1="21" y1="12" x2="9" y2="12"/>',
     lock:'<rect x="3" y="11" width="18" height="11" rx="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/>',
     inbox:'<polyline points="22 12 16 12 14 15 10 15 8 12 2 12"/><path d="M5.45 5.11L2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"/>'};
    const ic=(n,cls)=>{const s=document.createElement("span");s.className="ic "+(cls||"");s.innerHTML='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">'+P[n]+'</svg>';return s};
    const h=(tag,props,...kids)=>{const e=document.createElement(tag);for(const k in props||{}){const v=props[k];if(k==="class")e.className=v;else if(k.startsWith("on"))e.addEventListener(k.slice(2),v);else if(v!==false&&v!=null)e[k]=v}for(const c of kids.flat(9))if(c!=null&&c!==false)e.append(c.nodeType?c:document.createTextNode(String(c)));return e};

    /* ---------- Markdown: builds elements, never parses HTML ---------- */
    function inline(s){
      const out=[],re=/`([^`\n]+)`|\[([^\]\n]+)\]\((https?:\/\/[^\s)]+)\)|\*\*([^*\n]+?)\*\*|__([^_\n]+?)__|~~([^~\n]+?)~~|\*([^*\s][^*\n]*?)\*|(https?:\/\/[^\s<>)\]]+)/g;
      let last=0,m;
      while((m=re.exec(s))){
        if(m.index>last)out.push(s.slice(last,m.index));
        if(m[1]!=null)out.push(h("code",{},m[1]));
        else if(m[2]!=null)out.push(h("a",{href:m[3],target:"_blank",rel:"noopener noreferrer"},inline(m[2])));
        else if(m[4]!=null||m[5]!=null)out.push(h("strong",{},inline(m[4]||m[5])));
        else if(m[6]!=null)out.push(h("del",{},inline(m[6])));
        else if(m[7]!=null)out.push(h("em",{},inline(m[7])));
        else out.push(h("a",{href:m[8],target:"_blank",rel:"noopener noreferrer"},m[8]));
        last=re.lastIndex;
      }
      if(last<s.length)out.push(s.slice(last));
      return out;
    }
    const isTableSep=l=>/^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$/.test(l)&&l.includes("-");
    const cells=l=>l.trim().replace(/^\|/,"").replace(/\|$/,"").split("|").map(c=>c.trim());
    const startsBlock=l=>/^(```|#{1,6}\s|>|\s*([-*+]|\d+\.)\s|(-{3,}|\*{3,})\s*$)/.test(l);
    function md(src){
      const root=h("div",{class:"md"}),L=String(src).replace(/\r\n?/g,"\n").split("\n");let i=0,m;
      while(i<L.length){
        const l=L[i];
        if(/^```/.test(l)){const buf=[];i++;while(i<L.length&&!/^```/.test(L[i]))buf.push(L[i++]);i++;root.append(h("pre",{},h("code",{},buf.join("\n"))));continue}
        if(!l.trim()){i++;continue}
        if((m=/^(#{1,6})\s+(.*)$/.exec(l))){root.append(h("div",{class:"mh mh"+Math.min(m[1].length,3)},inline(m[2])));i++;continue}
        if(/^(-{3,}|\*{3,})\s*$/.test(l)){root.append(h("hr"));i++;continue}
        if(/^>/.test(l)){const buf=[];while(i<L.length&&/^>/.test(L[i]))buf.push(L[i++].replace(/^>\s?/,""));const q=md(buf.join("\n"));q.className="";root.append(h("blockquote",{},...q.childNodes));continue}
        if(l.includes("|")&&i+1<L.length&&isTableSep(L[i+1])){
          const head=cells(l);i+=2;const rows=[];while(i<L.length&&L[i].includes("|")&&L[i].trim())rows.push(cells(L[i++]));
          root.append(h("div",{class:"tw"},h("table",{},h("thead",{},h("tr",{},head.map(c=>h("th",{},inline(c))))),h("tbody",{},rows.map(r=>h("tr",{},r.map(c=>h("td",{},inline(c)))))))));continue}
        if(/^\s*([-*+]|\d+\.)\s+/.test(l)){
          const stack=[];let top=null;
          while(i<L.length&&(m=/^(\s*)([-*+]|\d+\.)\s+(.*)$/.exec(L[i]))){
            const depth=Math.floor(m[1].replace(/\t/g,"  ").length/2),ordered=/\d/.test(m[2]);
            while(stack.length&&stack[stack.length-1].depth>depth)stack.pop();
            if(!stack.length||stack[stack.length-1].depth<depth){const list=h(ordered?"ol":"ul");(stack.length?stack[stack.length-1].lastLi||stack[stack.length-1].el:root).append(list);stack.push({depth,el:list,lastLi:null});if(!top)top=list}
            const cur=stack[stack.length-1],li=h("li",{},inline(m[3]));cur.el.append(li);cur.lastLi=li;i++;
          }
          continue}
        const buf=[l];i++;while(i<L.length&&L[i].trim()&&!startsBlock(L[i])&&!(L[i].includes("|")&&i+1<L.length&&isTableSep(L[i+1])))buf.push(L[i++]);
        root.append(h("p",{},inline(buf.join(" "))));
      }
      return root;
    }
    const mdCache=new Map();
    function mdCached(m){const k=m.id+":"+m.text.length;let n=mdCache.get(k);if(!n){n=md(m.text);mdCache.set(k,n);if(mdCache.size>400)mdCache.delete(mdCache.keys().next().value)}return n}

    /* ---------- state ---------- */
    let st={approvals:[],sessions:[],repos:[],agents:[]},me={name:"",canApprove:false},paired=true,tab="board",open=null,msgs=[],lastRev=null,es=null,live=false,shell=null,access="editFiles",draftNew={},toastT=null;
    const api=async(method,path,body)=>{const r=await fetch(path,{method,headers:{"X-CPilot":"1","Content-Type":"application/json"},body:body?JSON.stringify(body):undefined,credentials:"same-origin"});
      let j={};try{j=await r.json()}catch(e){}if(r.status===401){paired=false;draw();throw new Error("unpaired")}if(!r.ok)throw new Error(j.error||("Error "+r.status));return j};
    const toast=(msg)=>{document.querySelectorAll(".toast").forEach(t=>t.remove());const t=h("div",{class:"toast"},msg);document.body.append(t);clearTimeout(toastT);toastT=setTimeout(()=>t.remove(),4200)};
    const act=async(fn)=>{try{await fn()}catch(e){if(e.message!=="unpaired")toast(e.message)}};
    const ago=t=>{const s=Math.max(0,Math.floor(Date.now()/1000-t));return s<45?"now":s<3600?Math.round(s/60)+"m":s<86400?Math.round(s/3600)+"h":Math.round(s/86400)+"d"};
    const STAT={approval:"Needs you",working:"Working",failed:"Failed",idle:"Idle"};

    function connect(){
      if(es)es.close();
      es=new EventSource("/v1/events");
      es.addEventListener("state",e=>{live=true;st=JSON.parse(e.data);onState()});
      es.onerror=async()=>{live=false;paintLive();try{await api("GET","/v1/me")}catch(e){}};
    }
    function paintLive(){document.querySelectorAll(".live").forEach(e=>{e.className="live"+(live?" on":"");e.lastChild.textContent=live?"Live":"Offline"})}
    async function onState(){
      if(open){const s=st.sessions.find(x=>x.id===open);const rev=s?(s.rev+":"+s.group+":"+(s.permissions||[]).length):"";if(rev!==lastRev){lastRev=rev;await loadMsgs()}else updateSession()}
      else draw();
      paintNav();
    }
    async function loadMsgs(){try{const j=await api("GET","/v1/sessions/"+open+"/messages");msgs=j.items;updateSession()}catch(e){}}

    /* ---------- shared pieces ---------- */
    const livePill=()=>h("span",{class:"live"+(live?" on":"")},h("i"),live?"Live":"Offline");
    const pageHeader=(title)=>h("div",{class:"top"},h("h1",{},title),livePill());
    const statusBadge=s=>h("div",{class:"badge "+s.group+(s.chief?" chief":"")},ic(s.group==="working"?"spinner":s.group==="approval"?"shield":s.group==="failed"?"alert":s.chief?"compass":"check",s.group==="working"?"spin":""));
    function sessionRow(s){return h("div",{class:"srow",onclick:()=>openSession(s.id)},statusBadge(s),
      h("div",{class:"grow"},h("div",{class:"t"},s.title),h("div",{class:"s"},s.repo+(s.branch?" · "+s.branch:""))),
      h("div",{class:"ago"},ago(s.updated)),h("span",{class:"chev"},ic("next")))}
    function approvalCards(){
      return st.approvals.map(a=>h("div",{class:"card amber"},h("div",{class:"row"},h("div",{class:"badge approval"},ic("shield")),h("div",{class:"grow"},h("div",{class:"t",style:"white-space:normal"},a.title))),
        h("div",{class:"s wrap",style:"white-space:pre-wrap;margin-top:8px"},a.detail),
        a.high&&!me.canApprove?h("div",{class:"hint row",style:"gap:8px"},ic("lock"),"This device may not approve pushes and merges. Answer at the Mac, or allow it in CPilot, Settings, Remote.")
        :h("div",{class:"acts"},h("button",{class:"btn primary",onclick:()=>act(()=>api("POST","/v1/approvals/"+a.id,{allow:true}))},ic("check"),"Allow once"),h("button",{class:"btn danger",onclick:()=>act(()=>api("POST","/v1/approvals/"+a.id,{allow:false}))},ic("x"),"Deny"))));
    }
    const seg=(opts,cur,onpick)=>{const box=h("div",{class:"seg"});opts.forEach(([v,l])=>box.append(h("button",{class:v===cur?"on":"",type:"button",onclick:()=>{onpick(v);[...box.children].forEach(b=>b.classList.toggle("on",b===box.children[opts.findIndex(o=>o[0]===v)]))}},l)));return box};
    const field=(label,el)=>[h("label",{},label),el];

    /* ---------- screens ---------- */
    function pairView(){
      const hash=new URLSearchParams(location.hash.slice(1));
      const code=h("input",{placeholder:"Pairing code",value:hash.get("pair")||"",autocapitalize:"off",autocomplete:"off",spellcheck:false});
      const name=h("input",{placeholder:"Name this device",value:/iPhone|iPad/.test(navigator.userAgent)?"iPhone":/Android/.test(navigator.userAgent)?"Android phone":"Phone"});
      const go=async()=>act(async()=>{await api("POST","/v1/pair",{code:code.value.trim(),name:name.value});history.replaceState(null,"",location.pathname);paired=true;await boot()});
      if(hash.get("pair"))setTimeout(go,60);
      return h("div",{},h("div",{class:"hero"},h("div",{class:"logo"},ic("compass")),h("h1",{},"CPilot"),h("div",{class:"s",style:"white-space:normal"},"Pair this device with your Mac")),
        h("div",{class:"card"},...field("Pairing code",code),...field("Device name",name),h("div",{class:"gap"}),h("button",{class:"btn primary block",onclick:go},ic("check"),"Pair"),
          h("div",{class:"hint"},"On the Mac: CPilot, Settings, Remote, Show pairing code. Scanning its QR code fills this in by itself.")));
    }

    function boardView(){
      const g=k=>st.sessions.filter(s=>s.group===k),need=g("approval").length+st.approvals.length,work=g("working").length;
      const sec=(label,list,n)=>list.length?[h("div",{class:"sec"},label,h("b",{},n??list.length)),...list.map(sessionRow)]:[];
      return h("div",{},pageHeader("Board"),
        (need||work)?h("div",{class:"chips"},need?h("span",{class:"chip warn"},ic("shield"),need+" need"+(need===1?"s":"")+" you"):null,work?h("span",{class:"chip acc"},ic("spinner","spin"),work+" working"):null):null,
        ...approvalCards(),...sec("Needs you",g("approval")),...sec("Working",g("working")),...sec("Failed",g("failed")),...sec("Recent",g("idle").slice(0,20)),
        st.sessions.length?null:h("div",{class:"empty"},ic("inbox"),h("b",{},"No sessions yet"),"Start one from New, or send the chief pilot an outcome."));
    }

    function newView(){
      if(!st.repos.length)return h("div",{},pageHeader("New session"),h("div",{class:"empty"},ic("inbox"),h("b",{},"No repositories yet"),"Open a repository in CPilot on the Mac first. A phone can only use repositories CPilot already knows."));
      const repo=h("select",{},st.repos.map(r=>h("option",{value:r.dir},r.name))),agent=h("select",{},st.agents.map(a=>h("option",{value:a.id},a.name)));
      const prompt=h("textarea",{placeholder:"What should the agent do?"});
      repo.value=draftNew.repo||st.repos[0].dir;repo.onchange=()=>draftNew.repo=repo.value;prompt.value=draftNew.prompt||"";prompt.oninput=()=>draftNew.prompt=prompt.value;
      const go=h("button",{class:"btn primary block",onclick:()=>act(async()=>{go.disabled=true;try{const j=await api("POST","/v1/sessions",{repo:repo.value,agent:agent.value,access,prompt:prompt.value});draftNew={};openSession(j.session_id)}finally{go.disabled=false}})},ic("bolt"),"Start session");
      return h("div",{},pageHeader("New session"),...approvalCards(),h("div",{class:"card"},
        ...field("Repository",repo),...(st.agents.length>1?field("Agent",agent):[]),
        ...field("Access",seg([["readOnly","Read only"],["askFirst","Ask first"],["editFiles","Edit files"]],access,v=>access=v)),
        ...field("Task",prompt),h("div",{class:"gap"}),go,
        h("div",{class:"hint"},"Runs on its own branch in a separate worktree, so your working folder is not touched. A phone can give at most Edit files.")));
    }

    function chiefView(){
      if(!st.repos.length)return h("div",{},pageHeader("Chief pilot"),h("div",{class:"empty"},ic("compass"),h("b",{},"No repositories yet"),"Open a repository in CPilot on the Mac first."));
      const repo=h("select",{},st.repos.map(r=>h("option",{value:r.dir},r.name))),text=h("textarea",{placeholder:"The outcome you want, in a few lines"});
      repo.value=draftNew.crepo||st.repos[0].dir;repo.onchange=()=>draftNew.crepo=repo.value;text.value=draftNew.ctext||"";text.oninput=()=>draftNew.ctext=text.value;
      const go=h("button",{class:"btn primary block",onclick:()=>act(async()=>{go.disabled=true;try{const j=await api("POST","/v1/chief",{repo:repo.value,text:text.value});draftNew.ctext="";openSession(j.session_id)}finally{go.disabled=false}})},ic("compass"),"Send to chief pilot");
      const chiefs=st.sessions.filter(s=>s.chief);
      return h("div",{},pageHeader("Chief pilot"),...approvalCards(),h("div",{class:"card"},...field("Repository",repo),...field("Outcome",text),h("div",{class:"gap"}),go,
        h("div",{class:"hint"},st.chiefMode==="asks"?"It writes the spec, runs the tasks and reviews, and asks you before it pushes and merges.":"It leads the work on its own: spec, tasks, review and merge, and tells you what it did.")),
        ...(chiefs.length?[h("div",{class:"sec"},"Chief pilots"),...chiefs.map(sessionRow)]:[]));
    }

    function meView(){
      return h("div",{},pageHeader("This device"),h("div",{class:"card"},h("div",{class:"row"},h("div",{class:"badge"},ic("phone")),h("div",{class:"grow"},h("div",{class:"t"},me.name||"Phone"),h("div",{class:"s"},live?"Connected to your Mac":"Not connected")))),
        h("div",{class:"card"},h("div",{class:"row"},h("div",{class:"badge"},ic(me.canApprove?"shield":"lock")),h("div",{class:"grow"},h("div",{class:"t"},me.canApprove?"Can approve push and merge":"Cannot approve push and merge"),
          h("div",{class:"s",style:"white-space:normal"},"Change this on the Mac: CPilot, Settings, Remote.")))),
        h("button",{class:"btn danger block",onclick:()=>act(async()=>{await api("POST","/v1/logout");paired=false;draw()})},ic("out"),"Sign out this device"),
        h("div",{class:"hint"},"To keep CPilot one tap away, use Share, then Add to Home Screen."));
    }

    /* ---------- session ---------- */
    function msgNode(m){
      if(m.kind==="user")return h("div",{class:"bubble"},m.text);
      if(m.kind==="assistant")return m.text.trim()?h("div",{class:"ans"},mdCached(m).cloneNode(true)):null;
      if(m.kind==="tool"){const cls=m.status==="failed"?"bad":m.status==="done"?"ok":"";return h("div",{class:"tool "+cls},ic("tool"),h("div",{class:"tx"},(m.title||"Tool")+(m.detail?" · "+m.detail:"")),m.status==="running"?ic("spinner","spin"):m.status==="done"?ic("check"):m.status==="failed"?ic("x"):null)}
      if(m.kind==="permission"){if(m.status==="pending")return null;return h("div",{class:"tool "+(m.status==="allowed"?"ok":"bad")},ic("shield"),h("div",{class:"tx"},(m.status==="allowed"?"Allowed · ":"Denied · ")+(m.title||"")+" "+(m.text||"")),ic(m.status==="allowed"?"check":"x"))}
      if(m.kind==="error")return h("div",{class:"err"},m.text);
      if(m.kind==="notice")return h("div",{class:"note"},m.text);
      return null;
    }
    function mountSession(){
      const box=h("textarea",{placeholder:"Message",rows:1,id:"composer"});
      const sendBtn=h("button",{class:"send",disabled:true,"aria-label":"Send"},ic("up"));
      const grow=()=>{box.style.height="auto";box.style.height=Math.min(box.scrollHeight,160)+"px";sendBtn.disabled=!box.value.trim()};
      const send=()=>act(async()=>{const t=box.value.trim();if(!t)return;box.value="";grow();await api("POST","/v1/sessions/"+open+"/messages",{text:t});setTimeout(()=>window.scrollTo(0,document.body.scrollHeight),50)});
      box.addEventListener("input",grow);box.addEventListener("keydown",e=>{if(e.key==="Enter"&&(e.metaKey||e.ctrlKey)){e.preventDefault();send()}});sendBtn.addEventListener("click",send);
      shell={bar:h("div",{class:"sbar"}),perms:h("div"),list:h("div"),comp:h("div",{class:"comp"},h("div",{class:"in"},box,sendBtn)),box};
      $("#app").replaceChildren(shell.bar,shell.perms,shell.list);document.body.append(shell.comp);
    }
    function unmountSession(){if(shell){shell.comp.remove();shell=null}}
    function updateSession(){
      if(!shell)return;
      const s=st.sessions.find(x=>x.id===open),near=window.innerHeight+window.scrollY>=document.body.scrollHeight-160;
      shell.bar.replaceChildren(h("button",{class:"iconbtn","aria-label":"Back",onclick:()=>{open=null;lastRev=null;draw();paintNav()}},ic("back")),
        h("div",{class:"grow"},h("div",{class:"t"},s?s.title:"Session"),h("div",{class:"s"},s?s.repo+(s.branch?" · "+s.branch:""):"")),
        s?h("span",{class:"stat "+s.group},STAT[s.group]):null,
        s&&s.group==="working"?h("button",{class:"iconbtn danger","aria-label":"Stop",onclick:()=>act(()=>api("POST","/v1/sessions/"+open+"/stop"))},ic("stop")):null);
      shell.perms.replaceChildren(...approvalCards(),...((s&&s.permissions)||[]).map(p=>h("div",{class:"card amber"},h("div",{class:"row"},h("div",{class:"badge approval"},ic("shield")),h("div",{class:"grow"},h("div",{class:"t"},"Allow "+p.tool+"?"))),
        h("div",{class:"s wrap",style:"white-space:pre-wrap;word-break:break-all;margin-top:8px"},p.summary),
        h("div",{class:"acts"},h("button",{class:"btn primary",onclick:()=>act(()=>api("POST","/v1/sessions/"+open+"/permissions/"+p.id,{allow:true}))},ic("check"),"Allow once"),h("button",{class:"btn danger",onclick:()=>act(()=>api("POST","/v1/sessions/"+open+"/permissions/"+p.id,{allow:false}))},ic("x"),"Deny")))));
      const nodes=msgs.map(msgNode).filter(Boolean);
      if(s&&s.group==="working")nodes.push(h("div",{class:"dots"},h("i"),h("i"),h("i")));
      if(!nodes.length)nodes.push(h("div",{class:"empty"},ic("inbox"),"No messages yet."));
      shell.list.replaceChildren(...nodes);
      if(near)window.scrollTo(0,document.body.scrollHeight);
    }
    async function openSession(id){open=id;msgs=[];lastRev=null;draw();paintNav();await loadMsgs();window.scrollTo(0,document.body.scrollHeight)}

    /* ---------- chrome ---------- */
    function paintNav(){
      const nav=$("#nav");
      if(!paired||open){nav.replaceChildren();document.body.classList.toggle("insession",!!open&&paired);return}
      document.body.classList.remove("insession");
      const need=st.sessions.filter(s=>s.group==="approval").length+st.approvals.length;
      const tabs=[["board","Board","list"],["chief","Chief","compass"],["new","New","plus"],["me","Device","phone"]];
      nav.replaceChildren(h("div",{class:"in"},...tabs.map(([k,l,i])=>h("button",{class:tab===k?"on":"",onclick:()=>{tab=k;draw();paintNav();window.scrollTo(0,0)}},ic(i),l,k==="board"&&need?h("span",{class:"n"},need):null))));
    }
    function draw(){
      if(!paired){unmountSession();$("#app").replaceChildren(pairView());paintNav();return}
      document.body.classList.toggle("insession",!!open);
      if(open){if(!shell)mountSession();updateSession();return}
      unmountSession();
      const a=document.activeElement;if(a&&a.matches&&a.matches("textarea,input,select")&&$("#app").contains(a))return;   // never rebuild a form someone is typing in
      $("#app").replaceChildren(tab==="new"?newView():tab==="chief"?chiefView():tab==="me"?meView():boardView());
    }
    async function boot(){try{me=await api("GET","/v1/me");st=await api("GET","/v1/state");paired=true;connect();draw();paintNav()}catch(e){draw()}}
    boot();
    </script></body></html>
    """#
}
