// Vanilla, no bundler. Execution-graph layout via d3-dag Sugiyama.
// Additive module — app.js still ships its own copy until cutover; this is the
// canonical source for future imports. Imports only loadD3.
import { loadD3 } from "../core/vendor.js";

export function metricsFor(n) {
  if (n.kind === "llm") return n.prompt_tokens + "/" + n.completion_tokens + " tok \u00b7 " + n.duration_ms + "ms";
  if (n.kind === "tool") return n.result_bytes + " B \u00b7 " + n.duration_ms + "ms";
  return "answer " + n.result_bytes + " B";
}

export function buildStages(nodes) {
  var stages = [];
  var final = null;
  nodes.forEach(function (n) {
    if (n.kind === "llm") stages.push({ iteration: n.iteration, llm: n, tools: [] });
    else if (n.kind === "tool" && stages.length) stages[stages.length - 1].tools.push(n);
    else if (n.kind === "final") final = n;
  });
  return { stages: stages, final: final };
}

export function graphSummaryText(built) {
  var parts = ["Execution graph:"];
  built.stages.forEach(function (stage) {
    var seg = "iteration " + stage.iteration + " called the model";
    if (stage.tools.length === 1) seg += ", then ran 1 tool (" + stage.tools[0].label + ")";
    else if (stage.tools.length > 1) seg += ", then ran " + stage.tools.length + " tools in parallel (" + stage.tools.map(function (t) { return t.label; }).join(", ") + ")";
    parts.push(seg + ".");
  });
  parts.push(built.final ? "The run ended with a final answer." : "The run ended without a final answer.");
  return parts.join(" ");
}

export function toDagInput(built) {
  var data = [];
  var parents = [];
  built.stages.forEach(function (stage) {
    var llmId = "n" + data.length;
    data.push({ id: llmId, parentIds: parents, kind: "llm", node: stage.llm, iteration: stage.iteration });
    if (stage.tools.length) {
      parents = stage.tools.map(function (tn) {
        var tid = "n" + data.length;
        data.push({ id: tid, parentIds: [llmId], kind: "tool", node: tn });
        return tid;
      });
    } else {
      parents = [llmId];
    }
  });
  if (data.length) {
    data.push(built.final
      ? { id: "n" + data.length, parentIds: parents, kind: "final", node: built.final }
      : { id: "n" + data.length, parentIds: parents, kind: "incomplete", node: null });
  }
  return data;
}

export function buildIncompleteNode(nodeW) {
  var stop = document.createElement("div");
  stop.className = "run-node-incomplete";
  stop.style.width = nodeW + "px";
  stop.textContent = "did not finish";
  var why = document.createElement("span");
  why.className = "sr-only";
  why.textContent = " \u2014 the run ended without a final answer, most likely hitting the iteration limit or the token budget.";
  stop.appendChild(why);
  return stop;
}

export function buildNodeBox(d, slowest, nodeW) {
  var kind = d.kind, node = d.node;
  var box = document.createElement("button");
  box.type = "button";
  box.className = "run-node";
  box.dataset.kind = kind;
  if (node.ok === false) box.dataset.ok = "false";
  if (/\[subagent run:\s*sub-\d+\]/.test(node.output || node.detail || "")) box.dataset.jump = "true";
  box.style.width = nodeW + "px";
  var kindEl = document.createElement("span");
  kindEl.className = "run-node-kind";
  kindEl.textContent = kind;
  box.appendChild(kindEl);
  var label = document.createElement("span");
  label.className = "run-node-label";
  // Trello/Slack-style: surface file refs + parent→child link inline on the card
  var jumpRe = /\[subagent run:\s*(sub-\d+)\]/;
  var jm = (node.output || node.detail || "").match(jumpRe);
  if (jm) {
    label.textContent = (node.label || node.detail || kind) + "  ↗ " + jm[1].slice(0, 10);
    label.title = (node.label || "") + (node.detail ? " · " + node.detail : "") + " — has sub-run " + jm[1] + " (open from detail)";
  } else {
    label.textContent = node.label || node.detail || kind;
    label.title = label.textContent;
  }
  // Kimi/Codex: if tool output names a source file, hint it under the metrics line
  var fileHint = null;
  var fm = (node.detail || node.label || "").match(/([a-zA-Z0-9_\-]+\.(?:zig|ts|js|py|rs|go|md))/);
  if (!fm && node.output) fm = node.output.slice(0, 600).match(/([a-zA-Z0-9_\-]+\.(?:zig|ts|js|py|rs|go|md))/);
  if (fm) fileHint = fm[1];
  box.appendChild(label);
  // Codex-like: show truncated duration on the card itself (Qwen's badge style)
  if (node.duration_ms) {
    var dur = document.createElement("span");
    dur.className = "run-node-duration";
    dur.textContent = (node.duration_ms < 1000 ? node.duration_ms + "ms" : (node.duration_ms/1000).toFixed(1) + "s");
    dur.setAttribute("aria-hidden", "true");
    box.appendChild(dur);
  }
  var metrics = document.createElement("span");
  metrics.className = "run-node-metrics";
  metrics.textContent = metricsFor(node) + (fileHint ? " · " + fileHint : "");
  box.appendChild(metrics);
  if (kind !== "final") {
    var bar = document.createElement("span");
    bar.className = "run-node-bar";
    var barFill = document.createElement("span");
    barFill.style.width = Math.max(2, Math.round((node.duration_ms || 0) / slowest * 100)) + "%";
    bar.appendChild(barFill);
    box.appendChild(bar);
  }
  box.setAttribute("data-label", node.label || node.detail || kind);
  box.setAttribute("aria-label", (node.ok === false ? "failed " : "") + kind + " " + (node.label || "") + ", " + metricsFor(node) + ". Activate to read its recorded output.");
  return box;
}

export function extendSubagentRefs(built) {
  // Slack / Trello habit: where node detail carries "[subagent run: sub-…]", make it clickable
  // by normalizing the text — graph's detail/output already contains the literal; the panel
  // below links it. No DOM here; app.js does the linking after layout.
  return built;
}

export function layoutGraph(canvas, built, slowest, opts) {
  opts = opts || {};
  var onSelect = opts.onSelect || function () {};
  var statusEl = opts.statusEl || null;
  var minimap = opts.minimap || null;
  var searchQuery = (opts.searchQuery || "").trim().toLowerCase();
  var kindFilter = (opts.kindFilter || "").trim().toLowerCase();
  var nodeW = 152, hGap = 32, vGap = 48, pad = 14;
  var tagPad = 42;
  var containerW = canvas.clientWidth || (canvas.parentElement && canvas.parentElement.clientWidth) || 320;
  var data = toDagInput(built);
  if (!data.length) return Promise.resolve();
  data.forEach(function (d) {
    d.el = d.kind === "incomplete" ? buildIncompleteNode(nodeW) : buildNodeBox(d, slowest, nodeW);
    d.el.style.visibility = "hidden";
    canvas.appendChild(d.el);
  });
  var nodeH = 0;
  data.forEach(function (d) { d.h = d.el.offsetHeight; nodeH = Math.max(nodeH, d.h); });
  return loadD3().then(function () {
    if (!canvas.isConnected) return;
    var dag;
    try { dag = window.d3.dagStratify()(data); } catch (e) {
      canvas.textContent = "";
      var errEl = document.createElement("p");
      errEl.className = "run-empty";
      errEl.textContent = "Could not lay out this run\u2019s graph: " + e.message;
      canvas.appendChild(errEl);
      if (statusEl) statusEl.textContent = errEl.textContent;
      return;
    }
    window.d3.sugiyama().nodeSize([nodeW + hGap, nodeH + vGap])(dag);
    var xs = [], ys = [];
    for (var dn0 of dag.idescendants()) { xs.push(dn0.x); ys.push(dn0.y); }
    var minX = Math.min.apply(null, xs), maxX = Math.max.apply(null, xs);
    var minY = Math.min.apply(null, ys), maxY = Math.max.apply(null, ys);
    var graphW = maxX - minX + nodeW;
    var graphH = maxY - minY + nodeH;
    var offsetX = pad + tagPad + nodeW / 2 - minX;
    var offsetY = pad + nodeH / 2 - minY;
    var totalW = Math.max(containerW, graphW + pad * 2 + tagPad);
    var totalH = graphH + pad * 2;
    canvas.style.height = totalH + "px";
    canvas.style.minHeight = totalH + "px";
    var svgNS = "http://www.w3.org/2000/svg";
    var svg = document.createElementNS(svgNS, "svg");
    svg.setAttribute("class", "run-edges");
    svg.setAttribute("width", totalW);
    svg.setAttribute("height", totalH);
    svg.setAttribute("aria-hidden", "true");
    var activeQuery = searchQuery || "";
    var hasKind = !!kindFilter;
    if (activeQuery || hasKind) {
      data.forEach(function(d){
        var hay = ((d.node && d.node.label) || "") + " " + ((d.node && d.node.detail) || "") + " " + d.kind;
        var hitsText = !activeQuery || hay.toLowerCase().indexOf(activeQuery) !== -1;
        var hitsKind = !hasKind || d.kind === kindFilter || (kindFilter === "failed" && d.node && d.node.ok === false);
        d._matches = hitsText && hitsKind;
        if (d._matches) { d.el.setAttribute("data-match", "true"); d.el.style.opacity = ""; }
        else { d.el.removeAttribute("data-match"); d.el.style.opacity = "0.28"; }
      });
      svg.style.opacity = "0.35";
      if (statusEl) {
        var n = data.filter(function(x){ return x._matches; }).length;
        statusEl.textContent = n + " of " + data.length + " nodes match" + (n ? "" : " — try Clear");
      }
    } else {
      data.forEach(function(d){ d.el.removeAttribute("data-match"); d.el.style.opacity = ""; });
      svg.style.opacity = "";
      if (statusEl) statusEl.textContent = "";
    }
    var defs = document.createElementNS(svgNS, "defs");
    var marker = document.createElementNS(svgNS, "marker");
    marker.setAttribute("id", "run-arrow");
    marker.setAttribute("viewBox", "0 0 8 8");
    marker.setAttribute("refX", "7"); marker.setAttribute("refY", "4");
    marker.setAttribute("markerWidth", "6"); marker.setAttribute("markerHeight", "6");
    marker.setAttribute("orient", "auto-start-reverse");
    var arrowPath = document.createElementNS(svgNS, "path");
    arrowPath.setAttribute("d", "M0,0 L8,4 L0,8 z");
    arrowPath.setAttribute("fill", "var(--border)");
    marker.appendChild(arrowPath); defs.appendChild(marker); svg.appendChild(defs);
    for (var link of dag.ilinks()) {
      var pts = link.points.map(function (p) { return [p.x + offsetX, p.y + offsetY]; });
      pts[0][1] = link.source.y + offsetY + link.source.data.h / 2;
      pts[pts.length - 1][1] = link.target.y + offsetY - link.target.data.h / 2 - 3;
      var d = "M" + pts[0][0] + "," + pts[0][1];
      for (var pi = 1; pi < pts.length; pi++) d += " L" + pts[pi][0] + "," + pts[pi][1];
      var path = document.createElementNS(svgNS, "path");
      path.setAttribute("d", d);
      path.setAttribute("marker-end", "url(#run-arrow)");
      svg.appendChild(path);
    }
    canvas.insertBefore(svg, canvas.firstChild);
    for (var dn of dag.idescendants()) {
      var cx = dn.x + offsetX, cy = dn.y + offsetY;
      var kind = dn.data.kind, box2 = dn.data.el;
      box2.style.left = (cx - nodeW / 2) + "px";
      box2.style.top = (cy - dn.data.h / 2) + "px";
      box2.style.visibility = "";
      if (kind === "incomplete") continue;
      if (kind === "llm") {
        var tag = document.createElement("span");
        tag.className = "run-iter-tag";
        tag.textContent = dn.data.iteration;
        tag.style.left = (cx - nodeW / 2 - 20) + "px";
        tag.style.top = (cy - 11) + "px";
        tag.setAttribute("aria-hidden", "true");
        canvas.appendChild(tag);
      }
      (function (k, n, b, iter) {
        function highlightPath(active){
          var id = b.dataset.graphId || "";
          canvas.querySelectorAll(".run-node[data-highlight]").forEach(function(x){ x.removeAttribute("data-highlight"); });
          canvas.querySelectorAll(".run-edges path[data-highlight]").forEach(function(x){ x.removeAttribute("data-highlight"); });
          if (!active || !id) return;
          try{
            var me = null;
            for (var ff of dag.idescendants()) if (ff.data.id === id) { me = ff; break; }
            if (!me) return;
            var upSeen = {}, downSeen = {};
            function markUp(dn2){ if (upSeen[dn2.data.id]) return; upSeen[dn2.data.id]=true; var el2 = dn2.data.el; if(el2) el2.setAttribute("data-highlight","true"); for (var p of dn2.iparents()) markUp(p); }
            function markDown(dn2){ if (downSeen[dn2.data.id]) return; downSeen[dn2.data.id]=true; var el2b = dn2.data.el; if(el2b) el2b.setAttribute("data-highlight","true"); for (var ch of dn2.ichildren()) markDown(ch); }
            markUp(me); markDown(me);
            var ps = canvas.querySelectorAll(".run-edges path");
            var idx=0;
            for (var lk of dag.ilinks()) {
              var pth = ps[idx++];
              if (!pth) continue;
              var sH = lk.source.data.el && lk.source.data.el.hasAttribute("data-highlight");
              var tH = lk.target.data.el && lk.target.data.el.hasAttribute("data-highlight");
              if (sH && tH) pth.setAttribute("data-highlight","true");
            }
          }catch(_e){}
        }
        b.dataset.graphId = dn.data.id;
        b.addEventListener("mouseenter", function(){ highlightPath(true); });
        b.addEventListener("mouseleave", function(){ highlightPath(false); });
        b.addEventListener("focus", function(){ highlightPath(true); });
        b.addEventListener("blur", function(){ highlightPath(false); });
        b.addEventListener("click", function () {
          canvas.querySelectorAll(".run-node.selected").forEach(function (x) { x.classList.remove("selected"); });
          b.classList.add("selected");
          onSelect(k, n);
          highlightPath(true);
          // keep URL in sync so Copy link after a click pins this node
          try {
            var cur = location.hash || "";
            var base = cur.split("?")[0];
            if (base.indexOf("#runs/") === 0) {
              var lbl = b.getAttribute("data-label") || "";
              var nextHash = base + (lbl ? "?node=" + encodeURIComponent(lbl) : "");
              if (location.hash !== nextHash) history.replaceState(null, "", nextHash);
            }
          } catch(_) {}
          try{
            document.querySelectorAll(".run-crumbs button").forEach(function(ch){
              if (ch.textContent.trim() === "iter " + iter) ch.setAttribute("aria-current","true"); else ch.removeAttribute("aria-current");
            });
          }catch(_){}
        });
      })(kind, dn.data.node, box2, dn.data.iteration);
    }
  }).catch(function (err) {
    var errEl2 = document.createElement("p");
    errEl2.className = "run-empty";
    errEl2.textContent = "Could not load the graph layout library: " + err.message;
    canvas.appendChild(errEl2);
    if (statusEl) statusEl.textContent = errEl2.textContent;
  });
}



