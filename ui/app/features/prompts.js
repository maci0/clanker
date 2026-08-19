// Prompts library — single-user. Browse / create / use / delete prompt templates backed by GET/POST/DELETE /api/prompts.
import { uiConfirm, toast, showLoadError } from "../core/ui.js";
import { readJson } from "../core/utils.js";
import { copyText } from "../core/vendor.js";

export function loadPromptsView() {
  var status = document.getElementById("prompts-status");
  if (status) status.textContent = "Loading…";
  return fetch("/api/prompts").then(readJson).then(function(data){
    var prompts = (data && data.prompts) || [];
    // renderPrompts ends in applyPromptFilter, which owns the status line: it
    // is the only thing that knows how many of the rendered cards are actually
    // on screen, and a count that ignores the filter contradicts the list.
    renderPrompts(prompts);
  }).catch(function(err){
    var msg = "Could not load prompts: " + err.message;
    if(status) status.textContent = msg;
    showLoadError(document.getElementById("prompts-list"), msg, loadPromptsView);
  });
}

/* What is on screen, decided in one place.
   The filter used to live only in the input handler, walking cards that already
   existed — so every re-render dropped it. Create, Delete and Refresh all
   rebuild the list, and each of them left every prompt showing while
   `#prompts-filter` still held the query, with `#prompts-status` reporting the
   full count. Called at the end of every render as well as on input, so the
   filter box and the list cannot disagree. */
function applyPromptFilter(){
  var listEl=document.getElementById("prompts-list");
  if(!listEl) return null;
  var filterEl=document.getElementById("prompts-filter");
  var raw=filterEl?filterEl.value.trim():"";
  var q=raw.toLowerCase();
  var cards=listEl.querySelectorAll(".prompt-card");
  var shown=0;
  cards.forEach(function(card){
    var hide=!!q&&(card.textContent||"").toLowerCase().indexOf(q)===-1;
    card.hidden=hide;
    if(!hide) shown++;
  });
  /* `#prompts-status` is `.sr-only`, so a filter that matched nothing left a
     blank panel and announced the reason to a screen reader only. The note goes
     where the cards were. It lives inside #prompts-list and so is thrown away
     by the next render's `textContent = ""`, which is why it is looked up
     rather than kept. */
  var note=document.getElementById("prompts-filter-empty");
  if(q&&cards.length&&!shown){
    if(!note){
      note=document.createElement("p");
      note.id="prompts-filter-empty";
      note.className="run-empty";
      listEl.appendChild(note);
    }
    note.textContent="";
    note.appendChild(document.createTextNode("No prompt matches “"+raw+"”. "));
    var clear=document.createElement("button");
    clear.type="button";
    clear.className="secondary";
    clear.textContent="Clear filter";
    clear.addEventListener("click",function(){
      if(filterEl){ filterEl.value=""; filterEl.focus(); }
      applyPromptFilter();
    });
    note.appendChild(clear);
    note.hidden=false;
  } else if(note) note.hidden=true;
  var status=document.getElementById("prompts-status");
  if(status){
    status.textContent=!cards.length
      ? "No prompts."
      : q ? shown+" of "+cards.length+(cards.length===1?" prompt shown.":" prompts shown.")
        : cards.length+(cards.length===1?" prompt.":" prompts.");
  }
  return { shown: shown, total: cards.length, query: q };
}

function renderPrompts(prompts){
  var listEl = document.getElementById("prompts-list");
  if(!listEl) return;
  listEl.textContent = "";
  if(!prompts.length){
    var empty=document.createElement("p"); empty.className="run-empty";
    empty.appendChild(document.createTextNode("No prompts yet. Save one from the chat composer or create it here. "));
    var start=document.createElement("button");
    start.type="button"; start.className="primary"; start.textContent="Create a prompt";
    start.addEventListener("click",function(){
      var title=document.getElementById("prompts-title");
      if(title){
        try{ title.scrollIntoView({behavior:"smooth",block:"center"}); }catch(_){}
        title.focus();
      }
    });
    empty.appendChild(start);
    listEl.appendChild(empty); applyPromptFilter(); return;
  }
  prompts.forEach(function(p){
    var card=document.createElement("div"); card.className="prompt-card";
    var head=document.createElement("div"); head.className="prompt-head";
    var title=document.createElement("strong"); title.textContent=p.title||p.id; head.appendChild(title);
    var useBtn=document.createElement("button"); useBtn.type="button"; useBtn.className="secondary"; useBtn.textContent="Use";
    useBtn.addEventListener("click",function(){ applyPromptToComposer(p.content); });
    head.appendChild(useBtn);
    var body=document.createElement("pre"); body.textContent=p.content;
    body.className="prompt-body";
    var copyBtn=document.createElement("button"); copyBtn.type="button"; copyBtn.className="secondary"; copyBtn.textContent="Copy";
    copyBtn.addEventListener("click",function(){
      copyText(p.content, copyBtn, "Copy", body);
    });
    head.appendChild(copyBtn);
    var delBtn=document.createElement("button"); delBtn.type="button"; delBtn.className="secondary danger"; delBtn.textContent="Delete";
    delBtn.addEventListener("click",function(){
      uiConfirm("Delete prompt \""+(p.title||p.id)+"\"?", { danger: true, confirmLabel: "Delete" }).then(function(yes){
        if(!yes) return;
        fetch("/api/prompts",{method:"DELETE",headers:{"Content-Type":"application/json"},body:JSON.stringify({id:p.id})})
          .then(readJson)
          .then(function(){ loadPromptsView(); try{ refreshLocalPrompts(); }catch(_){} })
          .catch(function(e){ toast(e.message); });
      });
    });
    head.appendChild(delBtn); card.appendChild(head);
    card.appendChild(body);
    var meta=document.createElement("div"); meta.className="meta";
    meta.textContent=p.id+(p.updated?" · "+new Date(p.updated*1000).toLocaleString():"");
    meta.style.marginTop="0.35rem"; card.appendChild(meta);
    listEl.appendChild(card);
  });
  applyPromptFilter();
}

/* The composer already refuses to restore a draft over typed text. Use used
   to assign through that guard, so an unsent task vanished when someone
   reached for a saved snippet. Confirm only when there is something to lose. */
function applyPromptToComposer(content){
  var dest=document.getElementById("task");
  if(!dest) return;
  function fill(){
    dest.value=content;
    dest.focus();
    try{ dest.dispatchEvent(new Event("input",{bubbles:true})); }catch(_){}
    try{ document.getElementById("tab-chat").click(); }catch(_){ window.location.hash="#chat"; }
  }
  if(dest.value.trim()){
    uiConfirm("Replace the unsent task with this prompt?", { confirmLabel: "Replace" }).then(function(yes){ if(yes) fill(); });
  } else fill();
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
    if(!title||!content){
      var missing = !title ? titleEl : contentEl;
      if(missing){ missing.setCustomValidity(!title ? "Give the prompt a title." : "Write the prompt text."); missing.reportValidity(); missing.setCustomValidity(""); }
      return;
    }
    if(title.length>200||content.length>20000){ toast("Title must be 1-200 characters and content 1-20000."); return; }
    if(createBtn) createBtn.disabled=true;
    fetch("/api/prompts",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({title:title,content:content})})
      .then(readJson)
      .then(function(){ if(titleEl) titleEl.value=""; if(contentEl) contentEl.value=""; loadPromptsView(); refreshLocalPrompts(); })
      .catch(function(e){ toast(e.message); }).finally(function(){ if(createBtn) createBtn.disabled=false; });
  });
  if(refreshBtn) refreshBtn.addEventListener("click",function(){ loadPromptsView(); });
  if(filterEl) filterEl.addEventListener("input",applyPromptFilter);
}
