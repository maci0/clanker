// Knowledge view — OpenWebUI parity single-user. Collections of documents.
export var selectedKnowledge = [];
function updateHint(){
  var hint=document.getElementById("knowledge-hint");
  if(!hint) return;
  hint.textContent = selectedKnowledge.length ? selectedKnowledge.length+" collection(s) will be included in the next prompt." : "No knowledge selected. Check collections to inject documents into the next chat.";
}
export function loadKnowledge(){
  var status=document.getElementById("knowledge-status");
  if(status) status.textContent="Loading…";
  return fetch("/api/knowledge").then(function(r){return r.json();}).then(function(data){
    var cols=(data&&data.collections)||[];
    var list=document.getElementById("knowledge-list");
    if(list){
      list.textContent="";
      if(!cols.length){
        var empty=document.createElement("p"); empty.className="run-empty"; empty.textContent="No collections yet. Create one to start adding documents.";
        list.appendChild(empty);
      } else cols.forEach(function(c){
        var card=document.createElement("div"); card.className="knowledge-card";
        var title=document.createElement("div"); title.className="knowledge-title";
        var cb=document.createElement("input"); cb.type="checkbox"; cb.value=c.id; cb.checked=selectedKnowledge.indexOf(c.id)!==-1;
        cb.setAttribute("aria-label","Include "+c.title+" in chat context");
        cb.addEventListener("change",function(){
          if(cb.checked){ if(selectedKnowledge.indexOf(c.id)===-1) selectedKnowledge.push(c.id); }
          else { var at=selectedKnowledge.indexOf(c.id); if(at!==-1) selectedKnowledge.splice(at,1); }
          updateHint();
        });
        title.appendChild(cb);
        var name=document.createElement("span"); name.textContent=" "+c.title+"  ·  "+c.doc_count+" docs  ·  "+(c.bytes||0)+" bytes";
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
    updateHint();
  }).catch(function(err){ if(status) status.textContent="Could not load knowledge: "+err.message; });
}
function openCollection(id){
  fetch("/api/knowledge/"+encodeURIComponent(id)).then(function(r){return r.json();}).then(function(data){
    var detail=document.getElementById("knowledge-detail"); if(!detail) return;
    detail.hidden=false; detail.textContent="";
    var head=document.createElement("div"); head.className="run-detail-head";
    var t=document.createElement("span"); t.className="run-detail-title"; t.textContent=data.title||id; head.appendChild(t);
    var close=document.createElement("button"); close.type="button"; close.className="secondary"; close.textContent="Close";
    close.addEventListener("click",function(){ detail.hidden=true; }); head.appendChild(close); detail.appendChild(head);
    if(data.description){ var desc=document.createElement("p"); desc.className="meta"; desc.textContent=data.description; detail.appendChild(desc); }
    var docs=data.docs||[];
    if(!docs.length){ var empty=document.createElement("p"); empty.className="meta"; empty.textContent="No documents yet. Add one below."; detail.appendChild(empty); }
    else docs.forEach(function(d){
      var row=document.createElement("div"); row.className="knowledge-doc";
      var dn=document.createElement("span"); dn.textContent=d.name+" ("+d.bytes+" bytes)"; row.appendChild(dn);
      var rm=document.createElement("button"); rm.type="button"; rm.className="secondary danger"; rm.textContent="Remove";
      rm.addEventListener("click",function(){
        if(!confirm("Remove "+d.name+"?")) return;
        fetch("/api/knowledge/"+encodeURIComponent(id)+"/docs/"+encodeURIComponent(d.id),{method:"DELETE"})
          .then(function(r){return r.json();}).then(function(){ openCollection(id); loadKnowledge(); }).catch(function(e){ alert(e.message); });
      });
      row.appendChild(rm);
      var pre=document.createElement("pre"); pre.className="knowledge-preview"; pre.textContent=(d.content||"").slice(0,800); row.appendChild(pre);
      detail.appendChild(row);
    });
    var addForm=document.createElement("form"); addForm.className="goal-form"; addForm.style.marginTop="1rem";
    var nLabel=document.createElement("label"); nLabel.textContent="New document name"; addForm.appendChild(nLabel);
    var nInput=document.createElement("input"); nInput.type="text"; nInput.placeholder="e.g. notes.md"; nInput.maxLength=200; addForm.appendChild(nInput);
    var cLabel=document.createElement("label"); cLabel.textContent="Content"; addForm.appendChild(cLabel);
    var cInput=document.createElement("textarea"); cInput.rows=6; cInput.placeholder="Paste document content…"; addForm.appendChild(cInput);
    var fileInput=document.createElement("input"); fileInput.type="file"; fileInput.accept=".txt,.md,.json,.csv,text/*";
    fileInput.addEventListener("change",function(){
      var f=fileInput.files&&fileInput.files[0]; if(!f) return;
      if(f.size>500000){ alert("File too large (max 500KB)."); return; }
      var fr=new FileReader(); fr.onload=function(){ cInput.value=String(fr.result||""); if(!nInput.value) nInput.value=f.name; }; fr.readAsText(f);
    });
    addForm.appendChild(fileInput);
    var submit=document.createElement("button"); submit.type="submit"; submit.className="secondary"; submit.textContent="Add document"; addForm.appendChild(submit);
    addForm.addEventListener("submit",function(e){
      e.preventDefault(); var name=nInput.value.trim(); var content=cInput.value;
      if(!name||!content.trim()){ alert("Name and content required."); return; }
      submit.disabled=true;
      fetch("/api/knowledge/"+encodeURIComponent(id)+"/docs",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({name:name,content:content})})
        .then(function(r){return r.json().then(function(d){ if(!r.ok||!d.ok) throw new Error(d.error||r.status); return d; });})
        .then(function(){ openCollection(id); loadKnowledge(); }).catch(function(err){ alert(err.message); }).finally(function(){ submit.disabled=false; });
    });
    detail.appendChild(addForm);
    try{ detail.scrollIntoView({behavior:"smooth",block:"nearest"}); }catch(_){}
  }).catch(function(err){ alert(err.message); });
}
function deleteCollection(id,title){
  if(!confirm("Delete collection \""+title+"\" and all its documents?")) return;
  fetch("/api/knowledge/"+encodeURIComponent(id),{method:"DELETE"})
    .then(function(r){return r.json().then(function(d){ if(!r.ok||!d.ok) throw new Error(d.error||r.status); return d; });})
    .then(function(){ var at=selectedKnowledge.indexOf(id); if(at!==-1) selectedKnowledge.splice(at,1); var detail=document.getElementById("knowledge-detail"); if(detail) detail.hidden=true; loadKnowledge(); })
    .catch(function(err){ alert(err.message); });
}
export function bindKnowledge(){
  var createBtn=document.getElementById("knowledge-create");
  var titleInput=document.getElementById("knowledge-title");
  var descInput=document.getElementById("knowledge-desc");
  var refreshBtn=document.getElementById("knowledge-refresh");
  var searchInput=document.getElementById("knowledge-search");
  var searchBtn=document.getElementById("knowledge-search-btn");
  var searchOut=document.getElementById("knowledge-search-out");
  if(createBtn) createBtn.addEventListener("click",function(){
    var title=titleInput?titleInput.value.trim():""; var desc=descInput?descInput.value.trim():"";
    if(!title){ alert("Title required."); return; }
    createBtn.disabled=true;
    fetch("/api/knowledge",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({title:title,description:desc})})
      .then(function(r){return r.json().then(function(d){ if(!r.ok||!d.ok) throw new Error(d.error||r.status); return d; });})
      .then(function(){ if(titleInput) titleInput.value=""; if(descInput) descInput.value=""; loadKnowledge(); })
      .catch(function(err){ alert(err.message); }).finally(function(){ createBtn.disabled=false; });
  });
  if(refreshBtn) refreshBtn.addEventListener("click",function(){ loadKnowledge(); });
  function doSearch(){
    var q=searchInput?searchInput.value.trim():""; if(!q){ if(searchOut) searchOut.textContent=""; return; }
    if(searchOut) searchOut.textContent="Searching…";
    fetch("/api/knowledge/search?q="+encodeURIComponent(q)).then(function(r){return r.json();}).then(function(data){
      var hits=(data&&data.hits)||[]; if(!searchOut) return; searchOut.textContent="";
      if(!hits.length){ searchOut.textContent="No matches."; return; }
      hits.forEach(function(h){
        var row=document.createElement("div"); row.className="knowledge-hit";
        var meta=document.createElement("div"); meta.className="meta"; meta.textContent=h.collection_title+" / "+h.doc_name; row.appendChild(meta);
        var snip=document.createElement("div"); snip.textContent=h.snippet; row.appendChild(snip); searchOut.appendChild(row);
      });
    }).catch(function(err){ if(searchOut) searchOut.textContent=err.message; });
  }
  if(searchBtn) searchBtn.addEventListener("click",doSearch);
  if(searchInput) searchInput.addEventListener("keydown",function(e){ if(e.key==="Enter"){ e.preventDefault(); doSearch(); } });
}
