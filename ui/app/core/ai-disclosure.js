// Turn heading helpers for the chat transcript. Disclosure banners and
// "AI" chrome were removed; the page is an operator panel, not a marketed
// AI feature surface.

export var ANSWER_LABEL = "Response";

/** Heading row for each assistant answer. */
export function createAnswerHead() {
  var head = document.createElement("div");
  head.className = "turn-assistant-head";
  head.setAttribute("role", "heading");
  head.setAttribute("aria-level", "3");
  var label = document.createElement("span");
  label.className = "turn-answer-label";
  label.textContent = ANSWER_LABEL;
  head.appendChild(label);
  return head;
}
