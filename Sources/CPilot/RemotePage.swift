// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The page a paired phone opens. One file, no build step and no library; model text is only ever inserted with `textContent`.
enum RemotePage {
    static let manifest = ##"{"name":"CPilot","short_name":"CPilot","start_url":"/","display":"standalone","background_color":"#111114","theme_color":"#111114"}"##

    static let html = #"""
    <!doctype html>
    <html lang="en"><head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="apple-mobile-web-app-title" content="CPilot">
    <meta name="theme-color" content="#111114">
    <link rel="manifest" href="/manifest.json">
    <title>CPilot</title>
    <style>
    :root{--bg:#f5f5f7;--card:#fff;--ink:#1c1c1e;--dim:#6e6e73;--line:#e2e2e6;--accent:#0a84ff;--ok:#30a14e;--warn:#d98200;--bad:#d9322e}
    @media(prefers-color-scheme:dark){:root{--bg:#111114;--card:#1c1c20;--ink:#f2f2f4;--dim:#9a9aa2;--line:#2c2c32;--accent:#4aa3ff;--ok:#43c463;--warn:#f0a030;--bad:#ff6b66}}
    *{box-sizing:border-box}html,body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.4 -apple-system,system-ui,sans-serif}
    body{padding:0 16px calc(76px + env(safe-area-inset-bottom));max-width:720px;margin:0 auto}
    header{display:flex;align-items:center;gap:10px;padding:calc(14px + env(safe-area-inset-top)) 0 10px;position:sticky;top:0;background:var(--bg);z-index:3}
    h1{font-size:20px;margin:0;flex:1}.dot{width:10px;height:10px;border-radius:50%;background:var(--bad)}.dot.on{background:var(--ok)}
    .card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:12px 14px;margin:0 0 10px}
    .row{display:flex;gap:10px;align-items:center}.grow{flex:1;min-width:0}
    .t{font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.s{color:var(--dim);font-size:13px}
    h2{font-size:12px;letter-spacing:.06em;text-transform:uppercase;color:var(--dim);margin:18px 0 8px}
    button,select,textarea,input{font:inherit;color:var(--ink)}
    button{border:1px solid var(--line);background:var(--card);border-radius:10px;padding:10px 14px;min-height:44px}
    button.p{background:var(--accent);border-color:var(--accent);color:#fff;font-weight:600}button.d{color:var(--bad)}button:disabled{opacity:.45}
    select,textarea,input{width:100%;border:1px solid var(--line);background:var(--card);border-radius:10px;padding:10px 12px;margin:0 0 10px}
    textarea{min-height:110px;resize:vertical}
    nav{position:fixed;left:0;right:0;bottom:0;display:flex;background:var(--card);border-top:1px solid var(--line);padding-bottom:env(safe-area-inset-bottom);z-index:4}
    nav button{flex:1;border:0;border-radius:0;background:none;color:var(--dim);min-height:52px}nav button.on{color:var(--accent);font-weight:600}
    .badge{display:inline-block;min-width:18px;padding:0 6px;border-radius:9px;background:var(--bad);color:#fff;font-size:12px;text-align:center;margin-left:4px}
    .pill{font-size:12px;padding:2px 8px;border-radius:9px;border:1px solid var(--line);color:var(--dim)}
    .pill.working{color:var(--accent);border-color:var(--accent)}.pill.approval{color:var(--warn);border-color:var(--warn)}.pill.failed{color:var(--bad);border-color:var(--bad)}
    .msg{white-space:pre-wrap;word-wrap:break-word;margin:0 0 8px;padding:9px 12px;border-radius:12px;background:var(--card);border:1px solid var(--line)}
    .msg.user{background:var(--accent);border-color:var(--accent);color:#fff;margin-left:36px}.msg.tool,.msg.notice{font-size:13px;color:var(--dim);padding:6px 10px}
    .msg.error{color:var(--bad)}.bar{position:sticky;bottom:calc(64px + env(safe-area-inset-bottom));background:var(--bg);padding-top:8px}
    .warn{border-color:var(--warn)}.empty{color:var(--dim);text-align:center;padding:30px 0}
    </style></head><body>
    <header><h1 id="title">CPilot</h1><div class="dot" id="dot"></div></header>
    <main id="main"></main>
    <nav id="nav"></nav>
    <script>
    "use strict";
    const $=s=>document.querySelector(s);
    const h=(tag,props,...kids)=>{const e=document.createElement(tag);for(const k in props||{}){const v=props[k];if(k==="class")e.className=v;else if(k.startsWith("on"))e.addEventListener(k.slice(2),v);else if(v!==false&&v!=null)e[k]=v}for(const c of kids.flat())if(c!=null&&c!==false)e.append(c.nodeType?c:document.createTextNode(c));return e};
    const api=async(method,path,body)=>{const r=await fetch(path,{method,headers:{"X-CPilot":"1","Content-Type":"application/json"},body:body?JSON.stringify(body):undefined,credentials:"same-origin"});
      let j={};try{j=await r.json()}catch(e){}if(r.status===401){paired=false;render();throw new Error("unpaired")}if(!r.ok)throw new Error(j.error||("Error "+r.status));return j};
    let st={approvals:[],sessions:[],repos:[],agents:[]},me={canApprove:false},paired=true,tab="board",open=null,msgs=[],lastRev=null,es=null,err="";
    const act=async(fn)=>{try{err="";await fn()}catch(e){if(e.message!=="unpaired"){err=e.message;render()}}};

    function connect(){
      if(es)es.close();
      es=new EventSource("/v1/events");
      es.addEventListener("state",e=>{$("#dot").className="dot on";st=JSON.parse(e.data);onState()});
      es.onerror=async()=>{$("#dot").className="dot";try{await api("GET","/v1/me")}catch(e){}};
    }
    async function onState(){
      if(open){const s=st.sessions.find(x=>x.id===open);const rev=s?(s.rev+":"+s.group+":"+(s.permissions||[]).length):"";if(rev!==lastRev){lastRev=rev;await loadMsgs()}}
      render();
    }
    async function loadMsgs(){try{const j=await api("GET","/v1/sessions/"+open+"/messages");msgs=j.items;render(true)}catch(e){}}

    function pairView(){
      const hash=new URLSearchParams(location.hash.slice(1));
      const code=h("input",{placeholder:"Pairing code",value:hash.get("pair")||"",autocapitalize:"off",autocomplete:"off"});
      const name=h("input",{placeholder:"Name this device",value:/iPhone|iPad/.test(navigator.userAgent)?"iPhone":"Phone"});
      const go=()=>act(async()=>{await api("POST","/v1/pair",{code:code.value.trim(),name:name.value});history.replaceState(null,"",location.pathname);paired=true;await boot()});
      if(hash.get("pair")&&!err)setTimeout(go,50);
      return h("div",{},h("div",{class:"card"},h("div",{class:"t"},"Pair this device"),h("div",{class:"s"},"On the Mac: CPilot, Settings, Remote, Pair a phone. Scan the code, or type it here."),h("br"),code,name,h("button",{class:"p",onclick:go},"Pair")),err&&h("div",{class:"card warn"},err));
    }

    function approvalCards(){
      const out=[];
      for(const a of st.approvals)out.push(h("div",{class:"card warn"},h("div",{class:"t"},a.title),h("div",{class:"s",style:"white-space:pre-wrap"},a.detail),h("br"),
        a.high&&!me.canApprove?h("div",{class:"s"},"This device may not approve pushes and merges. Answer at the Mac."):h("div",{class:"row"},
          h("button",{class:"p grow",onclick:()=>act(()=>api("POST","/v1/approvals/"+a.id,{allow:true}))},"Allow once"),h("button",{class:"grow d",onclick:()=>act(()=>api("POST","/v1/approvals/"+a.id,{allow:false}))},"Deny"))));
      return out;
    }

    const pill=g=>h("span",{class:"pill "+g},{approval:"needs you",working:"working",failed:"failed",idle:"idle"}[g]||g);
    function sessionRow(s){return h("div",{class:"card",onclick:()=>openSession(s.id),style:"cursor:pointer"},h("div",{class:"row"},h("div",{class:"grow"},h("div",{class:"t"},(s.chief?"Chief pilot · ":"")+s.title),h("div",{class:"s"},s.repo+(s.branch?" · "+s.branch:""))),pill(s.group)))}

    function boardView(){
      const g=k=>st.sessions.filter(s=>s.group===k);
      const sec=(label,list)=>list.length?[h("h2",{},label),...list.map(sessionRow)]:[];
      const any=st.sessions.length;
      return h("div",{},...approvalCards(),...sec("Needs you",g("approval")),...sec("Working",g("working")),...sec("Failed",g("failed")),...sec("Recent",g("idle").slice(0,15)),!any&&h("div",{class:"empty"},"No sessions yet. Start one from New."));
    }

    function newView(){
      const repo=h("select",{},st.repos.map(r=>h("option",{value:r.dir},r.name)));
      const agent=h("select",{},st.agents.map(a=>h("option",{value:a.id},a.name)));
      const access=h("select",{},[["editFiles","Edit files"],["askFirst","Ask first"],["readOnly","Read only"]].map(([v,l])=>h("option",{value:v},l)));
      const prompt=h("textarea",{placeholder:"What should it do?"});
      const go=h("button",{class:"p",onclick:()=>act(async()=>{go.disabled=true;try{const j=await api("POST","/v1/sessions",{repo:repo.value,agent:agent.value,access:access.value,prompt:prompt.value});openSession(j.session_id)}finally{go.disabled=false}})},"Start session");
      return h("div",{},...approvalCards(),h("div",{class:"card"},h("div",{class:"s"},"Repository"),repo,h("div",{class:"s"},"Agent"),agent,h("div",{class:"s"},"Access (a phone can give at most Edit files)"),access,prompt,go,h("div",{class:"s"},"It runs in its own worktree and branch, so your working folder is not touched.")),err&&h("div",{class:"card warn"},err));
    }

    function chiefView(){
      const repo=h("select",{},st.repos.map(r=>h("option",{value:r.dir},r.name)));
      const text=h("textarea",{placeholder:"The outcome you want, in a few lines"});
      const go=h("button",{class:"p",onclick:()=>act(async()=>{go.disabled=true;try{const j=await api("POST","/v1/chief",{repo:repo.value,text:text.value});openSession(j.session_id)}finally{go.disabled=false}})},"Send to chief pilot");
      const chiefs=st.sessions.filter(s=>s.chief);
      return h("div",{},...approvalCards(),h("div",{class:"card"},h("div",{class:"s"},"Repository"),repo,text,go,h("div",{class:"s"},st.chiefMode==="asks"?"It asks you before it pushes and merges.":"It leads the work on its own: spec, tasks, review, merge.")),...(chiefs.length?[h("h2",{},"Chief pilots"),...chiefs.map(sessionRow)]:[]),err&&h("div",{class:"card warn"},err));
    }

    function sessionView(){
      const s=st.sessions.find(x=>x.id===open);
      const box=h("textarea",{placeholder:"Message",style:"min-height:60px;margin:0",id:"composer"});
      const send=()=>act(async()=>{const t=box.value.trim();if(!t)return;box.value="";await api("POST","/v1/sessions/"+open+"/messages",{text:t})});
      const perms=((s&&s.permissions)||[]).map(p=>h("div",{class:"card warn"},h("div",{class:"t"},p.tool),h("div",{class:"s",style:"white-space:pre-wrap;word-break:break-all"},p.summary),h("br"),
        h("div",{class:"row"},h("button",{class:"p grow",onclick:()=>act(()=>api("POST","/v1/sessions/"+open+"/permissions/"+p.id,{allow:true}))},"Allow once"),h("button",{class:"grow d",onclick:()=>act(()=>api("POST","/v1/sessions/"+open+"/permissions/"+p.id,{allow:false}))},"Deny"))));
      const rows=msgs.map(m=>{if(m.kind==="permission")return null;const label=m.kind==="tool"?(m.title||"tool")+(m.detail?": "+m.detail:""):m.text;return h("div",{class:"msg "+m.kind},label)});
      return h("div",{},h("div",{class:"row",style:"margin-bottom:10px"},h("button",{onclick:()=>{open=null;lastRev=null;render()}},"‹ Back"),h("div",{class:"grow t"},s?s.title:"Session"),s&&pill(s.group),
        s&&s.group==="working"?h("button",{class:"d",onclick:()=>act(()=>api("POST","/v1/sessions/"+open+"/stop"))},"Stop"):null),
        ...approvalCards(),...perms,...rows,err&&h("div",{class:"card warn"},err),
        h("div",{class:"bar"},h("div",{class:"row"},h("div",{class:"grow"},box),h("button",{class:"p",onclick:send},"Send"))));
    }

    async function openSession(id){open=id;msgs=[];lastRev=null;tab="board";render();await loadMsgs();window.scrollTo(0,document.body.scrollHeight)}

    function render(keepScroll){
      if(!paired){$("#nav").replaceChildren();$("#main").replaceChildren(pairView());return}
      const typing=document.activeElement&&document.activeElement.tagName==="TEXTAREA"&&$("#main").contains(document.activeElement);
      if(typing&&!open)return;                           // never rebuild a form while someone is typing in it
      const keep=open&&$("#composer")?$("#composer").value:"";
      const nearBottom=window.innerHeight+window.scrollY>=document.body.scrollHeight-120;
      const view=open?sessionView():tab==="new"?newView():tab==="chief"?chiefView():boardView();
      $("#main").replaceChildren(view);
      if(open){const c=$("#composer");if(c&&keep)c.value=keep;if(keepScroll&&nearBottom)window.scrollTo(0,document.body.scrollHeight)}
      const need=st.sessions.filter(s=>s.group==="approval").length+st.approvals.length;
      $("#nav").replaceChildren(...[["board","Board"],["new","New"],["chief","Chief"]].map(([k,l])=>h("button",{class:tab===k&&!open?"on":"",onclick:()=>{tab=k;open=null;err="";render()}},l,k==="board"&&need?h("span",{class:"badge"},need):null)));
    }

    async function boot(){try{me=await api("GET","/v1/me");st=await api("GET","/v1/state");paired=true;connect();render()}catch(e){render()}}
    boot();
    </script></body></html>
    """#
}
