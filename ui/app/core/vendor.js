export var vendorLoads = {};
export var tomlRegistered = false;

import { readJson } from "./utils.js";
export { readJson };

const vendorLoadTimeoutMs = 30000;

export function loadVendor(file, ready) {
  if (vendorLoads[file]) return vendorLoads[file];
  vendorLoads[file] = ready() ? Promise.resolve() : new Promise(function (resolve, reject) {
    var s = document.createElement("script");
    var timer = window.setTimeout(function () {
      done();
      reject(new Error("timed out loading " + file));
    }, vendorLoadTimeoutMs);
    function done() {
      window.clearTimeout(timer);
      s.remove();
      s.onload = null;
      s.onerror = null;
    }
    s.src = new URL("../vendor/" + file, import.meta.url).href;
    s.onload = function () {
      done();
      if (ready()) resolve();
      else reject(new Error(file + " loaded but exported nothing"));
    };
    s.onerror = function () {
      done();
      reject(new Error("could not load " + file));
    };
    document.head.appendChild(s);
  });
  vendorLoads[file].catch(function () { delete vendorLoads[file]; });
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

// Highlight a TOML textarea into the <pre><code> layered behind it. The
// trailing newline keeps the pre as tall as the textarea's last line; falling
// back to plain text means a missing vendor bundle costs colour, not the editor.
export function paintTomlInto(text, code) {
  return loadHljs().then(function () {
    code.innerHTML = window.hljs.highlight(text.value, { language: "toml", ignoreIllegals: true }).value;
    code.appendChild(document.createTextNode("\n"));
  }).catch(function () { code.textContent = text.value; });
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
