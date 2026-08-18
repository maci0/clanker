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
  // Disclosure pointing down: model pill and similar menus.
  chevronDown: ["M6 9l6 6 6-6"],
  // A question, drawn rather than typed.
  help: ["M9 9a3 3 0 114 2.8c-.8.4-1 1-1 1.7v.5", "M12 17.5v.01"],
  // A pencil: the card quick-edit / open controls.
  pencil: ["M15.5 4.5L19.5 8.5 8 20H4v-4L15.5 4.5z"],
  // Close: dismiss a panel or an in-progress action.
  close: ["M6.5 6.5l11 11", "M17.5 6.5l-11 11"],
  // A rightward arrow: move to the next column / move card.
  arrowRight: ["M4 12h16", "M13 5l7 7-7 7"],
  // Up/down arrows: the priority ladder's high and low ends.
  arrowUp: ["M12 19V5", "M6 12l6-6 6 6"],
  arrowDown: ["M12 5v14", "M6 12l6 6 6-6"],
  // A square: stop the running turn.
  stop: ["M7.5 7.5h9v9h-9z"],
  // A rule: the middle of the priority ladder.
  minus: ["M6 12h12"],
  // A calendar: due dates and the patient timeline.
  calendar: ["M5 5h14v15H5z", "M5 10h14", "M8.5 3v4", "M15.5 3v4"],
  // A trash can: delete, which cannot be undone.
  trash: ["M6 6l.8 11.6a1.6 1.6 0 001.6 1.4h7.2a1.6 1.6 0 001.6-1.4L18 6", "M4 6h16", "M9 6V4h6v2", "M10 10.5v5", "M14 10.5v5"],
  // A checklist: the subtasks box on a card.
  checklist: ["M5 5h14v14H5z", "M9 12l1.8 1.8 3.6-3.9"],
  // A struck circle: a card that something else is blocking.
  blocked: ["M12 5.5a6.5 6.5 0 110 13 6.5 6.5 0 010-13z", "M8 8l8 8"],
  // A target: the goal a card mirrors.
  goal: ["M12 5.5a6.5 6.5 0 110 13 6.5 6.5 0 010-13z", "M12 9.5a2.5 2.5 0 110 5 2.5 2.5 0 010-5z"],
  // A speech bubble: the activity feed on a card.
  activity: ["M5 5h14v11H9l-4 3V5z"],
  // A grid: the board layout toggle's board face.
  grid: ["M4 5h6.5v6.5H4z", "M13.5 5H20v6.5h-6.5z", "M4 12.5h6.5V19H4z", "M13.5 12.5H20V19h-6.5z"],
  // Three rules: the list layout toggle's list face.
  list: ["M4 6.5h16", "M4 12h16", "M4 17.5h16"],
  // A plus: add a card, a child item, a label.
  plus: ["M12 5v14", "M5 12h14"],
  // Three dots: the column overflow menu.
  more: ["M5.5 12h1", "M11.5 12h1", "M17.5 12h1"],
  // Disclosure, pointing at what it closes.
  chevronLeft: ["M15 6l-6 6 6 6"],
  // A start actuator: press to run the goal. Key stays `rocket` for callers.
  rocket: ["M7.5 5h9v14h-9z", "M10.5 9.5l5 2.5-5 2.5z"],
  // A person: members and assign-to-me.
  person: ["M12 5a3 3 0 100 6 3 3 0 000-6z", "M6 19c0-3.2 2.7-5 6-5s6 1.8 6 5"],
  // A microphone: voice input.
  mic: ["M12 4.5a2.5 2.5 0 00-2.5 2.5v5a2.5 2.5 0 005 0v-5A2.5 2.5 0 0012 4.5z", "M7.5 11.5a4.5 4.5 0 009 0", "M12 16v3.5", "M9 19.5h6"],
  // A cycle: refresh a listing.
  refresh: ["M19 12a7 7 0 11-2.1-4.9", "M17 4.5V8h3.5"],
  // A star: a card marked to keep in view.
  star: ["M12 4l2.2 4.6 5 .7-3.6 3.5.9 5L12 15.8 7.5 17.8l.9-5L4.8 9.3l5-.7z"],
  // A panel with a rail: collapse or expand the sidebar.
  panel: ["M5 5h14v14H5z", "M10 5v14"],
  // A trunk with a second line branching off it, each ending in a node: a
  // git worktree, i.e. work that lives on its own branch beside the checkout.
  worktree: ["M7 7.5v9", "M7 11.5h8",
    "M7 3.5a2 2 0 110 4 2 2 0 010-4z",
    "M7 16.5a2 2 0 110 4 2 2 0 010-4z",
    "M17 9.5a2 2 0 110 4 2 2 0 010-4z"],
  // rh-ui-icon-ai-experience: sparkle cluster + experience frame.
  aiSparkle: [
    "M6 4l.9 2.4L4.5 8.5l2.6.9-1.4 2.4 1.5-2.6-1.4-2.4 2.6-.9-1.5-2.4 2.4 1.4.9-2.4z",
    "M14 9h6v6h-6z",
  ],
  // Circle-i for persistent review notices.
  aiInfo: ["M12 5.5a6.5 6.5 0 110 13 6.5 6.5 0 010-13z", "M12 11v5", "M12 8h.01"],
  // A face: the rooms emoji picker trigger.
  smile: ["M12 5.5a6.5 6.5 0 110 13 6.5 6.5 0 010-13z", "M9 10v.5", "M15 10v.5", "M8.5 14c1.1 1.6 2.7 2.4 3.5 2.4s2.4-.8 3.5-2.4"],
  // Transport. The music dock typed these from three Unicode blocks at once
  // (U+23xx bars, U+25B6 triangle, U+1F50A speaker) -- and the last two are
  // emoji, so a browser painted them in its own colours next to monochrome
  // ones. Drawn here they share the grid and the stroke like everything else.
  play: ["M9 6.5l9 5.5-9 5.5z"],
  pause: ["M9.5 6.5v11", "M14.5 6.5v11"],
  prev: ["M7 6.5v11", "M18 6.5l-8.5 5.5L18 17.5z"],
  next: ["M17 6.5v11", "M6 6.5l8.5 5.5L6 17.5z"],
  // A speaker cone; the muted variant strikes it rather than changing shape,
  // so the two states read as one control.
  volume: ["M5 9.5h3l4-3.5v12l-4-3.5H5z", "M15 9.5a3.5 3.5 0 010 5"],
  mute: ["M5 9.5h3l4-3.5v12l-4-3.5H5z", "M15.5 10l4 4", "M19.5 10l-4 4"],
  // A note: the collapsed dock's handle.
  note: ["M10 17.5V6l8-1.5V16", "M8 15.5a2 2 0 100 4 2 2 0 000-4z", "M16 14a2 2 0 100 4 2 2 0 000-4z"],
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


