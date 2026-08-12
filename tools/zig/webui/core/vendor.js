// Vanilla, no bundler. ES module; also mirrors to window for classic app.js fallback.

export var vendorLoads = {};
export var tomlRegistered = false;

export function loadVendor(file, ready) {
  if (vendorLoads[file]) return vendorLoads[file];
  vendorLoads[file] = ready() ? Promise.resolve() : new Promise(function (resolve, reject) {
    var s = document.createElement("script");
    s.src = "/webui/vendor/" + file;
    s.onload = function () {
      if (ready()) resolve();
      else reject(new Error(file + " loaded but exported nothing"));
    };
    s.onerror = function () { reject(new Error("could not load " + file)); };
    document.head.appendChild(s);
  });
  return vendorLoads[file];
}

export function loadD3() {
  return loadVendor("d3-dag.min.js", function () { return !!(window.d3 && window.d3.dagStratify); });
}

export function registerToml() {
  if (tomlRegistered) return;
  tomlRegistered = true;
  window.hljs.registerLanguage("toml", function (hljs) {
    return {
      name: "TOML",
      case_insensitive: false,
      contains: [
        hljs.COMMENT("#", "$"),
        { className: "section", begin: /^\s*\[+/, end: /\]+/ },
        { className: "attr", begin: /^\s*[A-Za-z0-9_.-]+(?=\s*=)/ },
        { className: "meta", begin: /\b\d{4}-\d{2}-\d{2}([T ]\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})?)?\b/ },
        { className: "literal", begin: /\b(true|false)\b/ },
        hljs.QUOTE_STRING_MODE,
        hljs.APOS_STRING_MODE,
        hljs.C_NUMBER_MODE
      ]
    };
  });
}

export function loadHljs() {
  return loadVendor("hljs.min.js", function () { return !!window.hljs; }).then(registerToml);
}

export function loadMermaid() {
  return loadVendor("mermaid.min.js", function () { return !!(window.mermaid && window.mermaid.render); });
}

export var reducedMotion = (typeof window !== "undefined" && window.matchMedia)
  ? window.matchMedia("(prefers-reduced-motion: reduce)")
  : { matches: false };

export function scrollTo(node, block) {
  node.scrollIntoView({ block: block, behavior: reducedMotion.matches ? "auto" : "smooth" });
}

export function readJson(r) {
  return r.json().then(function (d) {
    if (!r.ok) throw new Error((d && d.error) || "HTTP " + r.status);
    return d;
  }, function () {
    if (!r.ok) throw new Error("HTTP " + r.status);
    return {};
  });
}

export function copyText(text, btn, restoreLabel, selectTarget) {
  function restore() {
    window.setTimeout(function () { btn.textContent = restoreLabel; }, 1400);
  }
  function selectInstead() {
    var sel = window.getSelection && window.getSelection();
    if (selectTarget && sel && document.createRange) {
      var range = document.createRange();
      range.selectNodeContents(selectTarget);
      sel.removeAllRanges();
      sel.addRange(range);
      btn.textContent = "Selected \u2014 press Ctrl+C";
    } else {
      btn.textContent = "Copy unavailable";
    }
    restore();
  }
  if (!navigator.clipboard || !window.isSecureContext) return selectInstead();
  navigator.clipboard.writeText(text).then(function () {
    btn.textContent = "Copied";
    restore();
  }, selectInstead);
}

export function getVendorLoads() { return vendorLoads; }

// Backward-compat: app.js classic script expects globals; keep duplicated there
// for now — mirror so future modules can import while app.js still works.
if (typeof window !== "undefined") {
  window.readJson = window.readJson || readJson;
  window.copyText = window.copyText || copyText;
  window.loadVendor = window.loadVendor || loadVendor;
  window.loadD3 = window.loadD3 || loadD3;
  window.loadHljs = window.loadHljs || loadHljs;
  window.registerToml = window.registerToml || registerToml;
  window.vendorLoads = window.vendorLoads || vendorLoads;
}
