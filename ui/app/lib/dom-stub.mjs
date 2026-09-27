// Tiny DOM for node tests of the markdown renderer. Only what
// renderMarkdown / inlineInto touch.
//
// installDom() rather than a module-scope assignment: bun test runs every
// suite in one process, so a stub installed at import time outlasted the file
// that wanted it and whichever suite loaded next inherited a document missing
// whatever this stub does not implement (graph.test.mjs's createElement-only
// stub, for one, is why renderMarkdown threw createDocumentFragment). The
// returned function puts the previous globals back. A suite calls it in its
// own `before` rather than trusting what it finds ambient, and there is
// exactly one `installDom` here: a second declaration of the same export
// silently wins, so a one that returns anything else leaves every caller's
// `after` hook calling a non-function.

// A listener the view installs and the test never runs. focus() and
// preventDefault() are here because app.js calls both.
function noop() { return undefined; }

function node(tag) {
  return {
    nodeType: tag ? 1 : 3,
    tagName: tag ? tag.toUpperCase() : undefined,
    childNodes: [],
    attributes: {},
    className: "",
    listeners: {},
    // A form element reads as "" before anyone types; app.js calls
    // `input.value.trim()` on mount.
    value: "",
    parentNode: null,
    textContent: "",
    appendChild: function (c) {
      this.childNodes.push(c);
      c.parentNode = this;
      return c;
    },
    setAttribute: function (k, v) { this.attributes[k] = String(v); },
    getAttribute: function (k) { return this.attributes[k]; },
    removeAttribute: function (k) { delete this.attributes[k]; },
    focus: noop,
    addEventListener: function (type, fn) {
      (this.listeners[type] = this.listeners[type] || []).push(fn);
    }
  };
}

// The handlers a view registered, so a test can run the shipped one instead of
// asserting that its source mentions an event name.
export function dispatch(el, type, event) {
  const handlers = (el && el.listeners && el.listeners[type]) || [];
  const ev = Object.assign({ preventDefault: noop }, event);
  handlers.forEach(function (fn) { fn(ev); });
  return handlers.length;
}

function syncText(el) {
  if (el.nodeType === 3) return el.textContent;
  return el.childNodes.map(syncText).join("");
}

const document = {
  createElement: function (tag) {
    var el = node(tag);
    Object.defineProperty(el, "textContent", {
      get: function () { return syncText(this); },
      set: function (v) { this.childNodes = []; if (v) this.childNodes.push(document.createTextNode(v)); }
    });
    return el;
  },
  createTextNode: function (text) {
    var el = node(null);
    el.nodeType = 3;
    el.textContent = String(text);
    return el;
  },
  createDocumentFragment: function () {
    return document.createElement("#fragment");
  }
};

document.head = document.createElement("head");

export function installDom() {
  const prevDocument = globalThis.document;
  const prevWindow = globalThis.window;
  globalThis.document = document;
  globalThis.window = globalThis;
  return function restoreDom() {
    globalThis.document = prevDocument;
    globalThis.window = prevWindow;
  };
}

export function serialize(el) {
  if (!el) return "";
  if (el.nodeType === 3) return el.textContent;
  if (el.tagName === "#FRAGMENT") return el.childNodes.map(serialize).join("");
  var attrs = "";
  if (el.className) attrs += " class=\"" + el.className + "\"";
  Object.keys(el.attributes).forEach(function (k) {
    if (k === "class") return;
    attrs += " " + k + "=\"" + el.attributes[k] + "\"";
  });
  var inner = el.childNodes.map(serialize).join("");
  var tag = el.tagName.toLowerCase();
  return "<" + tag + attrs + ">" + inner + "</" + tag + ">";
}
