// Knowledge view — single-user. Collections of documents.
import { uiConfirm, uiPrompt, toast, showLoadError } from "../core/ui.js";
import { readJson, fmtBytes } from "../core/utils.js";
export var selectedKnowledge = (function(){ try { var raw = window.localStorage.getItem("clanker.knowledge"); if (raw) return JSON.parse(raw); } catch(_){} return []; })();
function persistKnowledge(){ try { window.localStorage.setItem("clanker.knowledge", JSON.stringify(selectedKnowledge)); } catch(_){} }
function ensureBadge(){
  var existing = document.getElementById("knowledge-badge");
  if (existing) return existing;
  var composer = document.getElementById("task-form");
  var badge = document.createElement("div");
  badge.id = "knowledge-badge";
  badge.className = "meta knowledge-badge";
  if (composer) composer.insertBefore(badge, composer.querySelector(".toolbar") || null);
  return badge;
}
function refreshBadge(){
  var badge = ensureBadge();
  if (!badge) return;
  if (!selectedKnowledge.length){ badge.style.display="none"; badge.textContent=""; return; }
  badge.style.display="block";
  // Reuse knowledge hint text when available
  var hint = document.getElementById("knowledge-hint");
  var n = selectedKnowledge.length;
  var msg = hint ? hint.textContent : (n + (n === 1 ? " collection" : " collections") + " will be included in the next prompt.");
  badge.textContent = msg + " ";
  var clear = document.createElement("button");
  clear.type="button"; clear.className="secondary knowledge-badge-clear"; clear.textContent="Don't include in next chat";
  clear.addEventListener("click", function(){ selectedKnowledge.length=0; persistKnowledge(); updateHint(); refreshBadge(); });
  badge.appendChild(clear);
}
function updateHint(){
  var hint=document.getElementById("knowledge-hint");
  if(!hint) return;
  var n = selectedKnowledge.length;
  hint.textContent = n
    ? n + (n === 1 ? " collection" : " collections") + " will be included in the next prompt."
    : "No knowledge selected. Check Include in chat on a collection to add its documents to the next chat.";
}
export function loadKnowledge(){
  var status=document.getElementById("knowledge-status");
  if(status) status.textContent="Loading…";
  return fetch("/api/knowledge").then(readJson).then(function(data){
    var cols=(data&&data.collections)||[];
    var list=document.getElementById("knowledge-list");
    if(list){
      list.textContent="";
      if(!cols.length){
        var empty=document.createElement("div"); empty.className="knowledge-empty";
        var heading=document.createElement("h3"); heading.textContent="No collections on file"; empty.appendChild(heading);
        var copy=document.createElement("p"); copy.textContent="Collections hold notes and reference material for chat context."; empty.appendChild(copy);
        var start=document.createElement("button"); start.type="button"; start.className="primary"; start.textContent="Add collection";
        start.addEventListener("click",function(){
          var title=document.getElementById("knowledge-title");
          if(title){ title.focus(); title.scrollIntoView({behavior:"smooth",block:"center"}); }
        });
        empty.appendChild(start); list.appendChild(empty);
      } else cols.forEach(function(c){
        var card=document.createElement("div"); card.className="knowledge-card";
        var title=document.createElement("div"); title.className="knowledge-title";
        var cb=document.createElement("input"); cb.type="checkbox"; cb.value=c.id; cb.checked=selectedKnowledge.indexOf(c.id)!==-1;
        cb.setAttribute("aria-label","Include "+c.title+" in chat");
        cb.addEventListener("change",function(){
          if(cb.checked){ if(selectedKnowledge.indexOf(c.id)===-1) selectedKnowledge.push(c.id); }
          else { var at=selectedKnowledge.indexOf(c.id); if(at!==-1) selectedKnowledge.splice(at,1); }
          persistKnowledge(); updateHint(); refreshBadge();
        });
        var include=document.createElement("label");
        include.className="checkbox-row knowledge-include";
        include.appendChild(cb);
        var includeTxt=document.createElement("span"); includeTxt.textContent="Include in chat";
        include.appendChild(includeTxt);
        title.appendChild(include);
        var name=document.createElement("span"); name.className="knowledge-name";
        name.textContent=c.title+"  ·  "+c.doc_count+" docs  ·  "+fmtBytes(c.bytes||0);
        if(c.description) name.title=c.description; title.appendChild(name);
        var actions=document.createElement("span"); actions.className="knowledge-actions";
        var open=document.createElement("button"); open.type="button"; open.className="secondary"; open.textContent="Open";
        open.addEventListener("click",function(){ openCollection(c.id); }); actions.appendChild(open);
        var del=document.createElement("button"); del.type="button"; del.className="secondary danger"; del.textContent="Delete";
        del.addEventListener("click",function(){ deleteCollection(c.id,c.title); }); actions.appendChild(del);
        title.appendChild(actions); card.appendChild(title); list.appendChild(card);
      });
    }
    if(status) status.textContent=cols.length+(cols.length===1?" collection.":" collections.");
    updateHint(); refreshBadge();
    var pending = typeof window !== "undefined" ? window._pendingKnowledgeId : null;
    if (pending) {
      window._pendingKnowledgeId = null;
      openCollection(pending);
    }
  }).catch(function(err){
    var msg="Could not load knowledge: "+err.message;
    if(status) status.textContent=msg;
    showLoadError(document.getElementById("knowledge-list"), msg, loadKnowledge);
  });
}
/* Folder-linked collections: which server-side folder a collection mirrors.
   The link lives in this browser (localStorage) rather than in the
   collection itself — the sync endpoint is stateless, and the collection's
   own schema stays untouched. */
var syncOpenId = null;
function savedSyncPath(id){ try { return window.localStorage.getItem("clanker.kbSync." + id) || ""; } catch(_){ return ""; } }
function rememberSyncPath(id, path){ try { window.localStorage.setItem("clanker.kbSync." + id, path); } catch(_){} }
function showSyncRow(id){
  // Set before the DOM guard, not after it: this is "which collection is
  // open", and closeCollection compares against it. Making it conditional on
  // the row's markup being present would let a delete miss the close.
  syncOpenId = id;
  var row = document.getElementById("knowledge-sync-row");
  var input = document.getElementById("knowledge-sync-path");
  if(!row || !input) return;
  input.value = savedSyncPath(id);
  row.hidden = false;
}
/* The row belongs to the open collection, and in index.html it is a *sibling*
   of #knowledge-detail rather than a child of it — so hiding the detail did not
   hide the row. Closing a collection left "Linked folder" on screen still
   pointed at it, and deleting the open collection left the row pointed at a
   collection the server had just removed: "Sync changes" then POSTed to a dead
   id and reported the failure as if the path were wrong. Every place that puts
   the detail away goes through here instead. */
function closeCollection(){
  var detail = document.getElementById("knowledge-detail");
  if(detail){ detail.hidden = true; detail.textContent = ""; }
  var row = document.getElementById("knowledge-sync-row");
  if(row) row.hidden = true;
  // Not just the row: the id is what runFolderSync sends, and it must not
  // outlive the collection either.
  syncOpenId = null;
}
function fillPreview(row, text) {
  var full = text || "";
  var pre = document.createElement("pre");
  pre.className = "knowledge-preview";
  var cap = 800;
  if (full.length <= cap) {
    pre.textContent = full;
    row.appendChild(pre);
    return;
  }
  pre.textContent = full.slice(0, cap);
  row.appendChild(pre);
  var more = document.createElement("button");
  more.type = "button";
  more.className = "secondary";
  more.textContent = "Show all";
  more.title = "Show the rest of this document (" + full.length + " characters)";
  more.addEventListener("click", function () {
    pre.textContent = full;
    more.remove();
  });
  row.appendChild(more);
}
function runFolderSync(){
  var input = document.getElementById("knowledge-sync-path");
  var prune = document.getElementById("knowledge-sync-prune");
  var btn = document.getElementById("knowledge-sync-btn");
  var status = document.getElementById("knowledge-status");
  if(!syncOpenId || !input) return;
  var path = input.value.trim();
  if(!path){ if(status) status.textContent = "Enter the folder path on the server."; return; }
  rememberSyncPath(syncOpenId, path);
  btn.disabled = true;
  fetch("/api/knowledge/"+encodeURIComponent(syncOpenId)+"/sync", {
    method: "POST", headers: {"Content-Type":"application/json"},
    body: JSON.stringify({ path: path, prune: !!(prune && prune.checked) })
  }).then(readJson)
    .then(function(d){
      if(status) status.textContent = "Synced " + d.synced + " document(s)" + (d.removed ? ", removed " + d.removed : "") + (d.skipped ? ", skipped " + d.skipped : "") + "." + (d.prune_skipped ? " Prune was skipped: the folder listing was incomplete, so a missing document may just be an unread file." : "");
      openCollection(syncOpenId); loadKnowledge();
    })
    .catch(function(err){ if(status) status.textContent = "Sync failed: " + err.message; })
    .finally(function(){ btn.disabled = false; });
}

function openCollection(id, docId){
  fetch("/api/knowledge/"+encodeURIComponent(id)).then(readJson).then(function(data){
    var detail=document.getElementById("knowledge-detail"); if(!detail) return;
    detail.hidden=false; detail.textContent="";
    showSyncRow(id);
    var head=document.createElement("div"); head.className="run-detail-head";
    var t=document.createElement("span"); t.className="run-detail-title"; t.textContent=data.title||id; head.appendChild(t);
    var share=document.createElement("button"); share.type="button"; share.className="secondary"; share.textContent="Copy link"; share.style.marginLeft="0.5rem";
    share.addEventListener("click", function(){
      var url = window.location.origin + window.location.pathname + "#knowledge/" + encodeURIComponent(id);
      if (!navigator.clipboard || !window.isSecureContext) { uiPrompt("Share link", url); return; }
      navigator.clipboard.writeText(url).then(function(){
        share.textContent="Copied"; setTimeout(function(){ share.textContent="Copy link"; }, 1200);
      }, function(){ uiPrompt("Share link", url); });
    }); head.appendChild(share);
    var close=document.createElement("button"); close.type="button"; close.className="secondary"; close.textContent="Close";
    close.addEventListener("click",closeCollection); head.appendChild(close); detail.appendChild(head);
    if(data.description){ var desc=document.createElement("p"); desc.className="meta"; desc.textContent=data.description; detail.appendChild(desc); }
    var docs=data.docs||[];
    if(!docs.length){ var empty=document.createElement("p"); empty.className="meta"; empty.textContent="No documents yet. Add one below."; detail.appendChild(empty); }
    else docs.forEach(function(d){
      var row=document.createElement("div"); row.className="knowledge-doc";
      var dn=document.createElement("span"); dn.textContent=d.name+" ("+d.bytes+" bytes)"; row.appendChild(dn);
      var rm=document.createElement("button"); rm.type="button"; rm.className="secondary danger"; rm.textContent="Remove";
      rm.addEventListener("click",function(){
        uiConfirm("Remove "+d.name+"?", { danger: true, confirmLabel: "Remove" }).then(function(yes){
          if(!yes) return;
          fetch("/api/knowledge/"+encodeURIComponent(id)+"/docs/"+encodeURIComponent(d.id),{method:"DELETE"})
            .then(readJson).then(function(){ openCollection(id); loadKnowledge(); }).catch(function(e){ toast(e.message); });
        });
      });
      row.appendChild(rm);
      fillPreview(row, d.content || "");
      if(docId && d.id===docId){
        row.setAttribute("data-found","true");
        try{ row.scrollIntoView({behavior:"smooth",block:"center"}); }catch(_){}
      }
      detail.appendChild(row);
    });
    var addForm=document.createElement("form"); addForm.className="goal-form"; addForm.style.marginTop="1rem";
    var nId="knowledge-new-doc-name";
    var nLabel=document.createElement("label"); nLabel.setAttribute("for", nId); nLabel.textContent="New document name"; addForm.appendChild(nLabel);
    var nInput=document.createElement("input"); nInput.type="text"; nInput.id=nId; nInput.placeholder="e.g. notes.md"; nInput.maxLength=200; nInput.required=true; addForm.appendChild(nInput);
    var cId="knowledge-new-doc-content";
    var cLabel=document.createElement("label"); cLabel.setAttribute("for", cId); cLabel.textContent="Content"; addForm.appendChild(cLabel);
    var cInput=document.createElement("textarea"); cInput.id=cId; cInput.rows=6; cInput.placeholder="Paste document content…"; cInput.required=true; addForm.appendChild(cInput);
    var fId="knowledge-new-doc-file";
    var fLabel=document.createElement("label"); fLabel.setAttribute("for", fId); fLabel.textContent="Or attach a text file"; addForm.appendChild(fLabel);
    var fileInput=document.createElement("input"); fileInput.type="file"; fileInput.id=fId; fileInput.accept=".txt,.md,.json,.csv,text/*";
    fileInput.addEventListener("change",function(){
      var f=fileInput.files&&fileInput.files[0]; if(!f) return;
      if(f.size>500000){ toast("File too large (max 500KB)."); return; }
      var fr=new FileReader(); fr.onload=function(){ cInput.value=String(fr.result||""); if(!nInput.value) nInput.value=f.name; }; fr.readAsText(f);
    });
    addForm.appendChild(fileInput);
    var submit=document.createElement("button"); submit.type="submit"; submit.className="primary"; submit.textContent="Add document"; addForm.appendChild(submit);
    addForm.addEventListener("submit",function(e){
      e.preventDefault(); var name=nInput.value.trim(); var content=cInput.value;
      if(!name||!content.trim()){ toast("Name and content are both required."); return; }
      submit.disabled=true;
      fetch("/api/knowledge/"+encodeURIComponent(id)+"/docs",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({name:name,content:content})})
        .then(readJson)
        .then(function(){ openCollection(id); loadKnowledge(); }).catch(function(err){ toast(err.message); }).finally(function(){ submit.disabled=false; });
    });
    detail.appendChild(addForm);
    if(!docId){
      try{ detail.scrollIntoView({behavior:"smooth",block:"nearest"}); }catch(_){}
    }
  }).catch(function(err){
    var detail=document.getElementById("knowledge-detail");
    if(detail){
      detail.hidden=false; detail.textContent="";
      var failed=document.createElement("p");
      failed.className="run-empty";
      failed.appendChild(document.createTextNode("Could not open this collection. "+err.message+" "));
      var retry=document.createElement("button");
      retry.type="button"; retry.className="secondary"; retry.textContent="Try again";
      retry.addEventListener("click",function(){ openCollection(id, docId); });
      failed.appendChild(retry);
      detail.appendChild(failed);
    }
    toast(err.message);
  });
}
function deleteCollection(id,title){
  uiConfirm("Delete collection \""+title+"\" and all its documents?", { danger: true, confirmLabel: "Delete" }).then(function(yes){
    if(!yes) return;
    fetch("/api/knowledge/"+encodeURIComponent(id),{method:"DELETE"})
      .then(readJson)
      .then(function(){ var at=selectedKnowledge.indexOf(id); if(at!==-1) selectedKnowledge.splice(at,1); if(syncOpenId===id) closeCollection(); loadKnowledge(); updateHint(); refreshBadge(); })
      .catch(function(err){ toast(err.message); });
  });
}
export function bindKnowledge(){
  var syncBtn=document.getElementById("knowledge-sync-btn");
  if(syncBtn) syncBtn.addEventListener("click", runFolderSync);
  var createForm=document.getElementById("knowledge-create-form");
  var createBtn=document.getElementById("knowledge-create");
  var titleInput=document.getElementById("knowledge-title");
  var descInput=document.getElementById("knowledge-desc");
  var refreshBtn=document.getElementById("knowledge-refresh");
  var searchInput=document.getElementById("knowledge-search");
  var searchBtn=document.getElementById("knowledge-search-btn");
  var searchOut=document.getElementById("knowledge-search-out");
  /* Submit rather than click, for the same reason the Prompts form does it:
     Enter in a text field is how every other form on this page is sent, and
     these two were the only ones where it either did nothing (here — two text
     fields suppress implicit submission) or reloaded the app (Prompts). */
  if(createForm) createForm.addEventListener("submit",function(e){
    e.preventDefault();
    var title=titleInput?titleInput.value.trim():""; var desc=descInput?descInput.value.trim():"";
    if(!title){
      if(titleInput){ titleInput.setCustomValidity("Give the collection a name."); titleInput.reportValidity(); titleInput.setCustomValidity(""); }
      return;
    }
    if(createBtn) createBtn.disabled=true;
    fetch("/api/knowledge",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({title:title,description:desc})})
      .then(readJson)
      .then(function(){ if(titleInput) titleInput.value=""; if(descInput) descInput.value=""; loadKnowledge(); })
      .catch(function(err){ toast(err.message); }).finally(function(){ if(createBtn) createBtn.disabled=false; });
  });
  if(refreshBtn) refreshBtn.addEventListener("click",function(){ loadKnowledge(); });
  function doSearch(){
    var q=searchInput?searchInput.value.trim():"";
    var status=document.getElementById("knowledge-status");
    if(!q){ if(searchOut) searchOut.textContent=""; if(status) status.textContent=""; return; }
    if(searchOut) searchOut.textContent="Searching…";
    if(status) status.textContent="Searching…";
    fetch("/api/knowledge/search?q="+encodeURIComponent(q)).then(readJson).then(function(data){
      var hits=(data&&data.hits)||[]; if(!searchOut) return; searchOut.textContent="";
      if(!hits.length){
        searchOut.textContent="";
        var none=document.createElement("p");
        none.className="run-empty";
        none.appendChild(document.createTextNode("No documents mention “"+q+"”. "));
        var clear=document.createElement("button");
        clear.type="button";
        clear.className="secondary";
        clear.textContent="Clear search";
        clear.addEventListener("click",function(){
          if(searchInput){ searchInput.value=""; searchInput.focus(); }
          searchOut.textContent="";
          if(status) status.textContent="";
        });
        none.appendChild(clear);
        searchOut.appendChild(none);
        if(status) status.textContent="No documents mention “"+q+"”.";
        return;
      }
      hits.forEach(function(h){
        var row=document.createElement("button");
        row.type="button";
        row.className="secondary search-hit knowledge-hit";
        var label=(h.collection_title||h.collection_id||"collection")+" / "+(h.doc_name||h.doc_id||"document");
        row.setAttribute("aria-label","Open "+label);
        var meta=document.createElement("div"); meta.className="search-hit-head";
        var title=document.createElement("span"); title.className="search-hit-title"; title.textContent=label;
        meta.appendChild(title); row.appendChild(meta);
        var snip=document.createElement("p"); snip.className="search-hit-snippet"; snip.textContent=h.snippet||"";
        row.appendChild(snip);
        row.addEventListener("click",function(){
          if(h.collection_id) openCollection(h.collection_id, h.doc_id);
        });
        searchOut.appendChild(row);
      });
      if(status) status.textContent=hits.length+(hits.length===1?" document.":" documents.");
    }).catch(function(err){
      var msg="Search failed: "+err.message;
      if(searchOut){
        searchOut.textContent="";
        var failed=document.createElement("p");
        failed.className="run-empty";
        failed.appendChild(document.createTextNode(msg+" "));
        var retry=document.createElement("button");
        retry.type="button"; retry.className="secondary"; retry.textContent="Try again";
        retry.addEventListener("click",doSearch);
        failed.appendChild(retry);
        searchOut.appendChild(failed);
      }
      if(status) status.textContent=msg;
    });
  }
  if(searchBtn) searchBtn.addEventListener("click",doSearch);
  if(searchInput) searchInput.addEventListener("keydown",function(e){ if(e.key==="Enter"){ e.preventDefault(); doSearch(); } });
}
