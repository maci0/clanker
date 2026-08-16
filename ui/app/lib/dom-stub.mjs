// Tiny DOM for node tests of the markdown renderer. Only what
// renderMarkdown / inlineInto touch.

function node(tag) {
  return {
    nodeType: tag ? 1 : 3,
    tagName: tag ? tag.toUpperCase() : undefined,
    childNodes: [],
    attributes: {},
    className: "",
    parentNode: null,
    textContent: tag ? "" : "",
    appendChild: function (c) {
      this.childNodes.push(c);
      c.parentNode = this;
      return c;
    },
    setAttribute: function (k, v) { this.attributes[k] = String(v); },
    getAttribute: function (k) { return this.attributes[k]; },
    addEventListener: function () {}
  };
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
globalThis.document = document;
globalThis.window = globalThis;

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
