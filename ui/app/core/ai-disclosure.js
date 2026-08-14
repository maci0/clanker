// Red Hat AI design-language disclosure helpers for the chat surface.
// Icons mirror rh-ui-icon-ai-* sparkle and the RH chatbot robot avatar.

import { icon } from "./icons.js";

export var AI_PRIVACY_NOTICE =
  "This feature uses AI technology. Do not include any personal information or other sensitive information in your input.";
export var AI_REVIEW_NOTICE = "Always review AI-generated content prior to use.";
export var AI_ANSWER_LABEL = "AI-assisted response";

var notice_key = "clanker.aiNoticeDismissed";

/** RH chatbot robot avatar (filled UI icon). */
export function robotAvatar(size) {
  var ns = "http://www.w3.org/2000/svg";
  var svg = document.createElementNS(ns, "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("width", String(size || 28));
  svg.setAttribute("height", String(size || 28));
  svg.setAttribute("aria-hidden", "true");
  svg.setAttribute("focusable", "false");
  svg.classList.add("ai-robot-avatar__svg");
  function rect(x, y, w, h, rx) {
    var r = document.createElementNS(ns, "rect");
    r.setAttribute("x", String(x));
    r.setAttribute("y", String(y));
    r.setAttribute("width", String(w));
    r.setAttribute("height", String(h));
    if (rx) r.setAttribute("rx", String(rx));
    r.setAttribute("fill", "currentColor");
    svg.appendChild(r);
  }
  rect(10.5, 3.5, 3, 1.5, 0.5);
  rect(11.25, 5, 1.5, 3.5, 0);
  rect(7, 9, 10, 9, 2);
  rect(9.5, 12, 1.75, 1.75, 0.35);
  rect(12.75, 12, 1.75, 1.75, 0.35);
  var smile = document.createElementNS(ns, "path");
  smile.setAttribute("d", "M9.5 15.5c1.2 1.1 2.4 1.1 3.5 0");
  smile.setAttribute("fill", "none");
  smile.setAttribute("stroke", "currentColor");
  smile.setAttribute("stroke-width", "1.5");
  smile.setAttribute("stroke-linecap", "square");
  svg.appendChild(smile);
  return svg;
}

export function aiTag(text) {
  var tag = document.createElement("span");
  tag.className = "ai-tag pf-v6-c-label pf-m-purple";
  tag.textContent = text || "AI";
  return tag;
}

/** Heading row for each assistant answer: robot + sparkle + label + AI tag. */
export function createAiAnswerHead() {
  var head = document.createElement("div");
  head.className = "turn-assistant-head";
  head.setAttribute("role", "heading");
  head.setAttribute("aria-level", "3");

  var avatarWrap = document.createElement("span");
  avatarWrap.className = "ai-robot-avatar";
  avatarWrap.appendChild(robotAvatar(28));
  head.appendChild(avatarWrap);

  var label = document.createElement("span");
  label.className = "ai-answer-label";
  label.appendChild(icon("aiSparkle", 16));
  label.appendChild(document.createTextNode(AI_ANSWER_LABEL));
  label.appendChild(aiTag("AI"));
  head.appendChild(label);
  return head;
}

function mountMastheadIndicator() {
  var slot = document.getElementById("ai-masthead-indicator");
  if (!slot || slot.dataset.ready === "1") return;
  slot.dataset.ready = "1";
  slot.appendChild(icon("aiSparkle", 16));
  slot.appendChild(aiTag("AI"));
}

function mountReviewNotice() {
  var notice = document.getElementById("ai-review-notice");
  if (!notice || notice.dataset.ready === "1") return;
  notice.dataset.ready = "1";
  var row = document.createElement("span");
  row.className = "ai-review-notice__row";
  row.appendChild(icon("aiInfo", 14));
  row.appendChild(document.createTextNode(AI_REVIEW_NOTICE));
  notice.appendChild(row);
}

function mountTransparencyBanner() {
  var banner = document.getElementById("ai-transparency-banner");
  if (!banner || banner.dataset.ready === "1") return;
  banner.dataset.ready = "1";
  try {
    if (window.localStorage.getItem(notice_key) === "1") banner.hidden = true;
  } catch (e) {}
  var iconSlot = banner.querySelector(".ai-transparency-banner__icon");
  if (iconSlot) iconSlot.appendChild(icon("aiSparkle", 18));
  var dismiss = document.getElementById("ai-transparency-dismiss");
  if (dismiss) {
    dismiss.addEventListener("click", function () {
      banner.hidden = true;
      try { window.localStorage.setItem(notice_key, "1"); } catch (e) {}
    });
    if (!dismiss.querySelector(".icon")) dismiss.appendChild(icon("close", 14));
  }
}

export function bindAiDisclosure() {
  mountMastheadIndicator();
  mountReviewNotice();
  mountTransparencyBanner();
}
