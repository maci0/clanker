// Prompts library — single-user. Browse / create / use / delete prompt templates backed by GET/POST/DELETE /api/prompts.
import { uiConfirm } from "../core/ui.js";
import { readJson } from "../core/utils.js";

export function loadPromptsView() {
  var status = document.getElementById("prompts-status");
  if (status) status.textContent = "Loading…";
  return fetch("/api/prompts").then(readJson).then(function(data){
    var prompts = (data && data.prompts) || [];
    renderPrompts(prompts);
    if (status) status.textContent = prompts.length + (prompts.length===1 ? " prompt." : " prompts.");
  }).catch(function(err){ if(status) status.textContent = "Could not load prompts: " + err.message; });
}

function renderPrompts(prompts){
  var listEl = document.getElementById("prompts-list");
  if(!listEl) return;
  listEl.textContent = "";
  if(!prompts.length){
    var empty=document.createElement("p"); empty.className="run-empty";
    empty.textContent="No prompts yet. Save one from the chat composer or create it here.";
    listEl.appendChild(empty); return;
  }
  prompts.forEach(function(p){
    var card=document.createElement("div"); card.className="prompt-card";
    card.style.cssText="border:1px solid var(--rule);border-radius:10px;padding:0.7rem 0.9rem;margin-bottom:0.6rem;background:var(--surface)";
    var head=document.createElement("div"); head.style.cssText="display:flex;align-items:center;gap:0.5rem;flex-wrap:wrap";
    var title=document.createElement("strong"); title.textContent=p.title||p.id; title.style.flex="1"; head.appendChild(title);
    var useBtn=document.createElement("button"); useBtn.type="button"; useBtn.className="secondary"; useBtn.textContent="Use";
    useBtn.addEventListener("click",function(){
      var dest=document.getElementById("task");
      if(dest){ dest.value=p.content; dest.focus(); try{ dest.dispatchEvent(new Event("input",{bubbles:true})); }catch(_){} }
      try{ document.getElementById("tab-chat").click(); }catch(_){ window.location.hash="#chat"; }
    });
    head.appendChild(useBtn);
    var copyBtn=document.createElement("button"); copyBtn.type="button"; copyBtn.className="secondary"; copyBtn.textContent="Copy";
    copyBtn.addEventListener("click",function(){
      try{ navigator.clipboard.writeText(p.content); copyBtn.textContent="Copied"; setTimeout(function(){ copyBtn.textContent="Copy"; },1200); }catch(_){}
    });
    head.appendChild(copyBtn);
    var delBtn=document.createElement("button"); delBtn.type="button"; delBtn.className="secondary danger"; delBtn.textContent="Delete";
    delBtn.addEventListener("click",function(){
      uiConfirm("Delete prompt \""+(p.title||p.id)+"\"?", { danger: true, confirmLabel: "Delete" }).then(function(yes){
        if(!yes) return;
        fetch("/api/prompts",{method:"DELETE",headers:{"Content-Type":"application/json"},body:JSON.stringify({id:p.id})})
          .then(readJson)
          .then(function(){ loadPromptsView(); try{ refreshLocalPrompts(); }catch(_){} })
          .catch(function(e){ alert(e.message); });
      });
    });
    head.appendChild(delBtn); card.appendChild(head);
    var body=document.createElement("pre"); body.textContent=p.content;
    body.style.cssText="white-space:pre-wrap;word-break:break-word;margin:0.5rem 0 0;font-size:13px;color:var(--fg-muted);max-height:9rem;overflow:auto";
    card.appendChild(body);
    var meta=document.createElement("div"); meta.className="meta";
    meta.textContent=p.id+(p.updated?" · "+new Date(p.updated*1000).toLocaleString():"");
    meta.style.marginTop="0.35rem"; card.appendChild(meta);
    listEl.appendChild(card);
  });
}

function refreshLocalPrompts(){
  try{
    fetch("/api/prompts").then(readJson).then(function(data){
      var server=(data&&data.prompts)||[];
      var texts=server.map(function(p){ return p.content; });
      try{ window.localStorage.setItem("clanker.prompts", JSON.stringify(texts)); }catch(_){}
    }).catch(function(){});
  }catch(_){}
}

export function bindPrompts(){
  var createForm=document.getElementById("prompts-create-form");
  var createBtn=document.getElementById("prompts-create");
  var titleEl=document.getElementById("prompts-title");
  var contentEl=document.getElementById("prompts-content");
  var refreshBtn=document.getElementById("prompts-refresh");
  var filterEl=document.getElementById("prompts-filter");
  /* On the form's submit, not the button's click. Title is the only field in
     here that blocks implicit submission (a textarea does not), so Enter in it
     submitted a form with no handler and no action: the browser navigated to
     the page's own URL and the whole app reloaded, taking the half-typed
     prompt with it. Submit covers the click too — the button is type=submit. */
  if(createForm) createForm.addEventListener("submit",function(e){
    e.preventDefault();
    var title=titleEl?titleEl.value.trim():"";
    var content=contentEl?contentEl.value.trim():"";
    if(!title||!content){ alert("Title and content required."); return; }
    if(title.length>200||content.length>20000){ alert("Title 1-200, content 1-20000."); return; }
    if(createBtn) createBtn.disabled=true;
    fetch("/api/prompts",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({title:title,content:content})})
      .then(readJson)
      .then(function(){ if(titleEl) titleEl.value=""; if(contentEl) contentEl.value=""; loadPromptsView(); refreshLocalPrompts(); })
      .catch(function(e){ alert(e.message); }).finally(function(){ if(createBtn) createBtn.disabled=false; });
  });
  if(refreshBtn) refreshBtn.addEventListener("click",function(){ loadPromptsView(); });
  if(filterEl) filterEl.addEventListener("input",function(){
    var q=filterEl.value.trim().toLowerCase();
    var cards=document.querySelectorAll("#prompts-list .prompt-card");
    cards.forEach(function(card){ var text=(card.textContent||"").toLowerCase(); card.hidden=!!q&&text.indexOf(q)===-1; });
  });
}
