// Drawn, not typed. One 24-grid, 1.75 stroke, square cap — so every
// icon shares a stroke with every other, which a star glyph and a
// multiplication sign (the previous "icon system") could not.

export var ICON_PATHS = {
  // A survey marker: the pin that says this layer matters.
  pin: ["M12 3.5v9", "M7.5 12.5h9l-1.5 3h-6z", "M12 15.5v5"],
  // Struck through: remove this entry.
  strike: ["M5.5 5.5l13 13", "M18.5 5.5l-13 13"],
  // A rule and tick: the depth column itself.
  log: ["M6 4v16", "M6 8h5", "M6 13h8", "M6 18h4"],
  // Loupe over the sheet.
  find: ["M11 4.5a6.5 6.5 0 100 13 6.5 6.5 0 000-13z", "M16 16l3.5 3.5"],
  // A sample vial: one recorded run.
  sample: ["M9.5 3.5h5", "M10.5 3.5v6L7 19a1.5 1.5 0 001.4 2h7.2a1.5 1.5 0 001.4-2l-3.5-9.5v-6"],
  // Two sheets: a copy.
  copy: ["M8.5 8.5h10v11h-10z", "M5.5 15.5v-11h10"],
  // A gate that held.
  held: ["M5 12.5l4.5 4.5L19 7.5"],
  // Deposited: an arrow settling onto the rule.
  deposit: ["M12 4v12", "M7.5 11.5L12 16l4.5-4.5", "M5 20h14"],
  // Disclosure, pointing at what it opens.
  chevron: ["M9 6l6 6-6 6"],
  // A question, drawn rather than typed.
  help: ["M9 9a3 3 0 114 2.8c-.8.4-1 1-1 1.7v.5", "M12 17.5v.01"],
};

export function icon(name, size) {
  var paths = ICON_PATHS[name];
  if (!paths) return document.createElement("span");
  var ns = "http://www.w3.org/2000/svg";
  var svg = document.createElementNS(ns, "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("width", String(size || 16));
  svg.setAttribute("height", String(size || 16));
  svg.setAttribute("fill", "none");
  svg.setAttribute("stroke", "currentColor");
  svg.setAttribute("stroke-width", "1.75");
  svg.setAttribute("stroke-linecap", "square");
  svg.setAttribute("stroke-linejoin", "miter");
  // Decorative in every use here: each icon sits beside or inside a control
  // that already carries its own accessible name.
  svg.setAttribute("aria-hidden", "true");
  svg.setAttribute("focusable", "false");
  svg.classList.add("icon");
  paths.forEach(function (d) {
    var path = document.createElementNS(ns, "path");
    path.setAttribute("d", d);
    svg.appendChild(path);
  });
  return svg;
}

if (typeof window !== "undefined") window.ckIcons = { ICON_PATHS: ICON_PATHS, icon: icon };
