// Knowledge view — single-user. Collections of documents.
import { uiConfirm, toast, showLoadError, requireText, runDetail as chrome } from "../core/ui.js";
import * as kit from "../core/kit.js";
import { reducedMotion, copyText } from "../core/vendor.js";
import { readJson, fmtBytes, wireRefresh, plural, showLoading } from "../core/utils.js";
export var selectedKnowledge = (function(){ try { var raw = window.localStorage.getItem("clanker.knowledge"); if (raw) return JSON.parse(raw); } catch(_){} return []; })();
function persistKnowledge(){ try { window.localStorage.setItem("clanker.knowledge", JSON.stringify(selectedKnowledge)); } catch(_){} }
function ensureBadge(){
  var existing = document.getElementById("knowledge-badge");
  if (existing) return existing;
  var composer = document.getElementById("task-form");
  var badge = document.createElement("div");
  badge.id = "knowledge-badge";
  badge.className = BADGE_CLASS;
  if (composer) composer.insertBefore(badge, composer.querySelector(".toolbar") || null);
  return badge;
}
function refreshBadge(){
  var badge = ensureBadge();
  if (!badge) return;
  if (!selectedKnowledge.length){ badge.hidden = true; badge.textContent=""; return; }
  badge.hidden = false;
  // Reuse knowledge hint text when available
  var hint = document.getElementById("knowledge-hint");
  var n = selectedKnowledge.length;
  var msg = hint ? hint.textContent : (plural(n, { one: "collection", other: "collections" }) + " will be included in the next prompt.");
  badge.textContent = msg + " ";
  var clear = kit.button({variant:"secondary", class: CLEAR_CLASS}, "Don't include in next chat");
  clear.addEventListener("click", function(){ selectedKnowledge.length=0; persistKnowledge(); updateHint(); refreshBadge(); });
  badge.appendChild(clear);
}
function updateHint(){
  var hint=document.getElementById("knowledge-hint");
  if(!hint) return;
  var n = selectedKnowledge.length;
  hint.textContent = n
    ? plural(n, { one: "collection", other: "collections" }) + " will be included in the next prompt."
    : "No knowledge selected. Check Include in chat on a collection to add its documents to the next chat.";
}
export function loadKnowledge(){
  var status=document.getElementById("knowledge-status");
  if(status) status.textContent="Loading…";
  showLoading(document.getElementById("knowledge-list"), "Loading collections…");
  return fetch("/api/knowledge").then(readJson).then(function(data){
    var cols=(data&&data.collections)||[];
    var list=document.getElementById("knowledge-list");
    if(list){
      list.textContent="";
      if(!cols.length){
        var empty=document.createElement("div"); empty.className=EMPTY_CLASS;
        var heading=document.createElement("h3"); heading.className=EMPTY_HEAD_CLASS; heading.textContent="No collections on file"; empty.appendChild(heading);
        var copy=document.createElement("p"); copy.className=EMPTY_COPY_CLASS; copy.textContent="Collections hold notes and reference material for chat context."; empty.appendChild(copy);
        var start=kit.button({variant:"primary"}, "Add collection");
        start.addEventListener("click",function(){
          var title=document.getElementById("knowledge-title");
          if(title){ title.focus(); title.scrollIntoView({behavior:reducedMotion.matches?"auto":"smooth",block:"center"}); }
        });
        empty.appendChild(start); list.appendChild(empty);
      } else cols.forEach(function(c){
        var card=document.createElement("div"); card.className=CARD_CLASS;
        var title=document.createElement("div"); title.className=TITLE_CLASS;
        var cb=document.createElement("input"); cb.type="checkbox"; cb.value=c.id; cb.checked=selectedKnowledge.indexOf(c.id)!==-1;
        cb.setAttribute("aria-label","Include "+c.title+" in chat");
        cb.addEventListener("change",function(){
          if(cb.checked){ if(selectedKnowledge.indexOf(c.id)===-1) selectedKnowledge.push(c.id); }
          else { var at=selectedKnowledge.indexOf(c.id); if(at!==-1) selectedKnowledge.splice(at,1); }
          persistKnowledge(); updateHint(); refreshBadge();
        });
        var include=document.createElement("label");
        include.className="m-0 inline-flex min-h-8 min-w-0 flex-none cursor-pointer items-center gap-1";
        include.appendChild(cb);
        var includeTxt=document.createElement("span"); includeTxt.textContent="Include in chat";
        include.appendChild(includeTxt);
        title.appendChild(include);
        var name=document.createElement("span"); name.className="min-w-0 flex-1 basis-48 wrap-anywhere";
        name.textContent=c.title+"  ·  "+c.doc_count+" docs  ·  "+fmtBytes(c.bytes||0);
        if(c.description) name.title=c.description; title.appendChild(name);
        var actions=document.createElement("span"); actions.className="ml-auto flex gap-2";
        var open=kit.button({variant:"secondary"}, "Open");
        open.addEventListener("click",function(){ openCollection(c.id); }); actions.appendChild(open);
        var del=kit.button({variant:"secondary-danger"}, "Delete");
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
  var cap = 800;
  if (full.length <= cap) {
    pre.textContent = full;
    row.appendChild(pre);
    return;
  }
  pre.textContent = full.slice(0, cap);
  row.appendChild(pre);
  var more = kit.button({variant:"secondary"}, "Show all");
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
  var go = function(){
    fetch("/api/knowledge/"+encodeURIComponent(syncOpenId)+"/sync", {
      method: "POST", headers: {"Content-Type":"application/json"},
      body: JSON.stringify({ path, prune: !!(prune && prune.checked) })
    }).then(readJson)
      .then(function(d){
        if(status) status.textContent = "Synced " + plural(d.synced, {one:"document", other:"documents"}) + (d.removed ? ", removed " + plural(d.removed, {one:"document", other:"documents"}) : "") + (d.skipped ? ", skipped " + d.skipped : "") + "." + (d.prune_skipped ? " Prune was skipped: the folder listing was incomplete, so a missing document may just be an unread file." : "");
        openCollection(syncOpenId); loadKnowledge();
      })
      .catch(function(err){ if(status) status.textContent = "Sync failed: " + err.message; })
      .finally(function(){ btn.disabled = false; });
  };
  // Prune deletes every document whose file is gone from the folder, so it
  // asks first like every other irreversible action here. The tick stays as it
  // was: cancelling a confirmation is not a reason to clear the intent.
  if(prune && prune.checked){
    btn.disabled = false;
    uiConfirm("Prune documents that are no longer in the folder? Every document in this collection whose file is missing from "+path+" is deleted. This cannot be undone.",
      { danger: true, confirmLabel: "Sync and prune" }).then(function(yes){
        if(!yes) return;
        btn.disabled = true;
        go();
      });
    return;
  }
  go();
}

/* The collection list and its cards, as Tailwind utilities over the cabinet
   tokens (ui/app/tailwind.src.css); the buttons come from the kit
   (core/kit.js). The badge shows and hides through the `hidden` attribute
   rather than an inline `display`, so the stylesheet and the token sweep both
   see one state. */
var BADGE_CLASS = "meta mt-1.5 rounded-plate-lg border border-dashed border-rule bg-surface-2 px-2 py-1.5";
var CLEAR_CLASS = "ml-2 px-1 py-0.5 text-xs";
var EMPTY_CLASS = "mt-6 max-w-2xl border-t border-rule py-4 text-left";
var EMPTY_HEAD_CLASS = "mt-0 mb-2 font-sans text-xs font-semibold text-fg-muted";
var EMPTY_COPY_CLASS = "mt-0 mb-4 max-w-[52ch] leading-relaxed text-fg-muted";
var CARD_CLASS = "border-b border-rule px-0.5 py-3";
var TITLE_CLASS = "flex flex-wrap items-center gap-x-3 gap-y-2";
/* A jumped-to document: the accent wash marks it without moving the row. */
var DOC_CLASS = "data-[found=true]:bg-accent-dim data-[found=true]:outline-1 data-[found=true]:outline-accent/35";

function openCollection(id, docId){
  // Clear before the fetch, not after: opening collection B while A is open
  // used to leave A's documents under B's title until B answered, and a slow
  // answer read as a click that did nothing.
  var pending=document.getElementById("knowledge-detail");
  if(pending){ pending.hidden=false; pending.textContent="Loading…"; }
  fetch("/api/knowledge/"+encodeURIComponent(id)).then(readJson).then(function(data){
    var detail=document.getElementById("knowledge-detail"); if(!detail) return;
    detail.hidden=false; detail.textContent="";
    showSyncRow(id);
    var head=document.createElement("div"); head.className=chrome.head;
    var t=document.createElement("span"); t.className=chrome.title; t.textContent=data.title||id; head.appendChild(t);
    var share=kit.button({variant:"secondary", class:"ml-3"}, "Copy link");
    share.addEventListener("click", function(){
      var url = window.location.origin + window.location.pathname + "#knowledge/" + encodeURIComponent(id);
      // The shared copy path, for the same reason the session Share button
      // uses it: a `uiPrompt` fallback offered a "Save" button on a link the
      // reader only wanted, and a clipboard refusal is common enough on plain
      // http to be a path, not an edge.
      copyText(url, share, "Copy link");
    }); head.appendChild(share);
    var close=kit.button({variant:"secondary"}, "Close");
    close.addEventListener("click",closeCollection); head.appendChild(close); detail.appendChild(head);
    if(data.description){ var desc=document.createElement("p"); desc.className="meta"; desc.textContent=data.description; detail.appendChild(desc); }
    var docs=data.docs||[];
    if(!docs.length){ var empty=document.createElement("p"); empty.className="meta"; empty.textContent="No documents yet. Add one below."; detail.appendChild(empty); }
    else docs.forEach(function(d){
      var row=document.createElement("div"); row.className=DOC_CLASS;
      var dn=document.createElement("span"); dn.textContent=d.name+" ("+d.bytes+" bytes)"; row.appendChild(dn);
      var rm=kit.button({variant:"secondary-danger"}, "Delete");
      rm.addEventListener("click",function(){
        uiConfirm("Delete \""+d.name+"\"? This cannot be undone.", { danger: true, confirmLabel: "Delete" }).then(function(yes){
          if(!yes) return;
          fetch("/api/knowledge/"+encodeURIComponent(id)+"/docs/"+encodeURIComponent(d.id),{method:"DELETE"})
            .then(readJson).then(function(){ toast("Deleted "+d.name+"."); openCollection(id); loadKnowledge(); }).catch(function(e){ toast(e.message); });
        });
      });
      row.appendChild(rm);
      fillPreview(row, d.content || "");
      if(docId && d.id===docId){
        row.setAttribute("data-found","true");
        try{ row.scrollIntoView({behavior:reducedMotion.matches?"auto":"smooth",block:"center"}); }catch(_){}
      }
      detail.appendChild(row);
    });
    var addForm=document.createElement("form"); addForm.className="goal-form mt-4";
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
    var submit=kit.button({variant:"primary", type:"submit"}, "Add document"); addForm.appendChild(submit);
    addForm.addEventListener("submit",function(e){
      e.preventDefault();
      // A toast cannot say which of the two fields is the empty one, and the
      // dialog stays open either way; the browser points at the field.
      if(!requireText(nInput, "Name the document.")) return;
      if(!requireText(cInput, "Give the document its content.")) return;
      var name=nInput.value.trim(); var content=cInput.value;
      submit.disabled=true;
      fetch("/api/knowledge/"+encodeURIComponent(id)+"/docs",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({name,content})})
        .then(readJson)
        .then(function(){ openCollection(id); loadKnowledge(); }).catch(function(err){ toast(err.message); }).finally(function(){ submit.disabled=false; });
    });
    detail.appendChild(addForm);
    if(!docId){
      try{ detail.scrollIntoView({behavior:reducedMotion.matches?"auto":"smooth",block:"nearest"}); }catch(_){}
    }
  }).catch(function(err){
    var detail=document.getElementById("knowledge-detail");
    if(detail){
      detail.hidden=false; detail.textContent="";
      var failed=document.createElement("p");
      failed.className="run-empty";
      failed.appendChild(document.createTextNode("Could not open this collection. "+err.message+" "));
      var retry=document.createElement("button");
      var retry = kit.button({variant:"secondary"}, "Try again");
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
      .then(function(){ toast("Deleted \""+title+"\"."); var at=selectedKnowledge.indexOf(id); if(at!==-1) selectedKnowledge.splice(at,1); if(syncOpenId===id) closeCollection(); loadKnowledge(); updateHint(); refreshBadge(); })
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
    var savedTitle=titleInput.value, savedDesc=descInput?descInput.value:"";
    fetch("/api/knowledge",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({title,description:desc})})
      .then(readJson)
      .then(function(){
        if(titleInput.value===savedTitle && (!descInput || descInput.value===savedDesc)){
          titleInput.value=""; if(descInput) descInput.value="";
        }
        loadKnowledge();
      })
      .catch(function(err){ toast(err.message); }).finally(function(){ if(createBtn) createBtn.disabled=false; });
  });
  wireRefresh(refreshBtn, loadKnowledge);
  var searchSequence = 0;
  function clearSearch(){
    searchSequence++;
    if(searchOut) searchOut.textContent="";
    var status=document.getElementById("knowledge-status");
    if(status) status.textContent="";
  }
  function doSearch(){
    var sequence = ++searchSequence;
    var q=searchInput?searchInput.value.trim():"";
    var status=document.getElementById("knowledge-status");
    if(!q){ if(searchOut) searchOut.textContent=""; if(status) status.textContent=""; return; }
    if(searchOut) searchOut.textContent="Searching…";
    if(status) status.textContent="Searching…";
    fetch("/api/knowledge/search?q="+encodeURIComponent(q)).then(readJson).then(function(data){
      if(sequence !== searchSequence) return;
      var hits=(data&&data.hits)||[]; if(!searchOut) return; searchOut.textContent="";
      if(!hits.length){
        searchOut.textContent="";
        var none=document.createElement("p");
        none.className="run-empty";
        none.appendChild(document.createTextNode("No documents mention “"+q+"”. "));
        var clear = kit.button({variant:"secondary"}, "Clear search");
        clear.addEventListener("click",function(){
          if(searchInput){ searchInput.value=""; searchInput.focus(); }
          clearSearch();
        });
        none.appendChild(clear);
        searchOut.appendChild(none);
        if(status) status.textContent="No documents mention “"+q+"”.";
        return;
      }
      hits.forEach(function(h){
        var row=document.createElement("button");
        row.type="button";
        row.className="secondary block mb-2 " + kit.recordRow.row;
        var label=(h.collection_title||h.collection_id||"collection")+" / "+(h.doc_name||h.doc_id||"document");
        row.setAttribute("aria-label","Open "+label);
        var meta=document.createElement("div"); meta.className=kit.recordRow.head;
        var title=document.createElement("span"); title.className=kit.recordRow.name; title.textContent=label;
        meta.appendChild(title); row.appendChild(meta);
        var snip=document.createElement("p"); snip.className=kit.recordRow.snippet; snip.textContent=h.snippet||"";
        row.appendChild(snip);
        row.addEventListener("click",function(){
          if(h.collection_id) openCollection(h.collection_id, h.doc_id);
        });
        searchOut.appendChild(row);
      });
      if(status) status.textContent=hits.length+(hits.length===1?" document.":" documents.");
    }).catch(function(err){
      if(sequence !== searchSequence) return;
      var msg="Search failed: "+err.message;
      if(searchOut){
        searchOut.textContent="";
        var failed=document.createElement("p");
        failed.className="run-empty";
        failed.appendChild(document.createTextNode(msg+" "));
        var retry = kit.button({variant:"secondary"}, "Try again");
        retry.addEventListener("click",doSearch);
        failed.appendChild(retry);
        searchOut.appendChild(failed);
      }
      if(status) status.textContent=msg;
    });
  }
  if(searchBtn) searchBtn.addEventListener("click",doSearch);
  if(searchInput){
    searchInput.addEventListener("keydown",function(e){ if(e.key==="Enter"){ e.preventDefault(); doSearch(); } });
    searchInput.addEventListener("input",clearSearch);
  }
}
