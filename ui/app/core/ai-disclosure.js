/* Turn heading helpers for the chat transcript. The page is an operator
   panel, so an answer is labelled as a response, never as "AI". */

export const ANSWER_LABEL = "Response",
  /** Heading row for each assistant answer. */
  createAnswerHead = () => {
    const head = document.createElement("div"),
      label = document.createElement("span");

    head.className = "mb-2 flex max-w-[min(42rem,92%)] items-center gap-3";
    head.setAttribute("role", "heading");
    head.setAttribute("aria-level", "3");
    label.className = "font-sans text-sm font-semibold text-fg-muted";
    label.textContent = ANSWER_LABEL;
    head.append(label);

    return head;
  };
