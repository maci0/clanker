// Drives the shipped hidden-form and primary-button rules. A PF form class
// on a [hidden] node paints it; a bare button must not be an accent pill.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const here = dirname(fileURLToPath(import.meta.url));
const css = readFileSync(join(here, "..", "app.css"), "utf8");
const html = readFileSync(join(here, "..", "index.html"), "utf8");
const uiSrc = readFileSync(join(here, "ui.js"), "utf8");

function ruleBody(selector) {
  const needle = selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const re = new RegExp(needle + "\\s*\\{([^}]+)\\}");
  const m = css.match(re);
  assert.ok(m, "missing rule for " + selector);
  return m[1];
}

function loadUpgradePfForm() {
  const m = /export function upgradePfForm\(el\) \{([\s\S]*?)\n\}/.exec(uiSrc);
  assert.ok(m, "upgradePfForm missing from ui.js");
  return new Function("el", m[1]);
}

test("card-form stays in the tree as a hidden compatibility form", function () {
  assert.match(html, /id="card-form"[^>]*\bhidden\b|id="card-form" hidden/);
});

test("author CSS hides a hidden form so PF display cannot leak it", function () {
  const body = ruleBody("form[hidden]");
  assert.match(body, /display:\s*none/);
});

test("upgradePfForm does not stamp pf-v6-c-form onto a hidden form", function () {
  const upgradePfForm = loadUpgradePfForm();
  var added = null;
  upgradePfForm({
    tagName: "FORM",
    hidden: true,
    hasAttribute: function (n) { return n === "hidden"; },
    classList: {
      contains: function () { return false; },
      add: function (c) { added = c; },
    },
  });
  assert.equal(added, null);

  added = null;
  upgradePfForm({
    tagName: "FORM",
    hidden: false,
    hasAttribute: function () { return false; },
    classList: {
      contains: function () { return false; },
      add: function (c) { added = c; },
    },
  });
  assert.equal(added, "pf-v6-c-form");
});

test("rooms log is not a live region; status is", function () {
  assert.match(html, /id="chat-log"[^>]*role="log"/);
  assert.doesNotMatch(html, /id="chat-log"[^>]*aria-live=/);
  assert.match(html, /id="chat-status"[^>]*aria-live="polite"/);
  assert.match(html, /Loading channels/);
});

test("progress log is not a live region; status is", function () {
  assert.match(html, /id="progress-log"[^>]*role="log"/);
  assert.doesNotMatch(html, /id="progress-log"[^>]*aria-live=/);
  assert.match(html, /id="progress-status"[^>]*aria-live="polite"/);
});

test("header model chip is not a live region", function () {
  assert.match(html, /id="header-model"/);
  assert.doesNotMatch(html, /id="header-model"[^>]*aria-live=/);
});

test("run graph measures node heights after one layout flush", function () {
  const graphSrc = readFileSync(join(here, "..", "lib", "graph.js"), "utf8");
  assert.match(graphSrc, /void canvas\.offsetHeight/);
  const writeThenRead = graphSrc.indexOf("canvas.appendChild(d.el)") < graphSrc.indexOf("void canvas.offsetHeight");
  assert.ok(writeThenRead, "append all nodes before reading offsetHeight");
});

test("theme toggle opens a list, not a cycle", function () {
  const themeSrc = readFileSync(join(here, "theme.js"), "utf8");
  assert.match(themeSrc, /export function bindThemeToggle/);
  assert.match(html, /id="theme-toggle"[^>]*aria-haspopup="listbox"/);
  assert.doesNotMatch(themeSrc, /THEMES\.indexOf\(theme\) \+ 1/);
});

test("settings and palette choose a theme instead of cycling", function () {
  assert.match(html, /id="settings-theme-cycle"[^>]*>Choose theme</);
  assert.doesNotMatch(html, />Cycle theme</);
  const pal = readFileSync(join(here, "palette.js"), "utf8");
  assert.match(pal, /label: "Choose theme"/);
  assert.doesNotMatch(pal, /Cycle theme/);
});

test("voice input copy matches click-to-start behavior", function () {
  assert.match(html, /id="voice-btn"[^>]*title="Voice input \(click to start\)"/);
  assert.doesNotMatch(html, /hold or click/);
});

test("phone composer suggestions and attachment remove are 44px", function () {
  assert.match(css, /#view-chat \.suggestion \{ min-height: 44px/);
  assert.match(css, /\.attachment button \{[\s\S]*min-height: 44px/);
});

test("Search sits in Work, not the folded Set up group", function () {
  const work = html.slice(html.indexOf('id="rail-section-work"'), html.indexOf('id="rail-section-watch"'));
  const setup = html.slice(html.indexOf('id="rail-section-setup"'));
  assert.match(work, /id="tab-search"/);
  assert.doesNotMatch(setup, /id="tab-search"/);
});

test("empty transcript names the new conversation, not Idle", function () {
  const empty = html.slice(html.indexOf('id="transcript-empty"'), html.indexOf('id="transcript-empty"') + 280);
  assert.match(empty, />New conversation</);
  assert.doesNotMatch(empty, />Idle</);
  assert.match(html, /id="session-title">New conversation</);
  assert.match(html, /id="chat-channel-title">Loading…</);
});

test("conversation filter says it matches titles", function () {
  assert.match(html, /id="session-filter"[^>]*placeholder="Filter by title…"/);
});

test("channel name pattern explains the allowed characters", function () {
  assert.match(html, /id="chat-new-room-name"[^>]*title="Letters, numbers, underscores, and hyphens only/);
  assert.match(html, /id="chat-new-room-hint"/);
});

test("workspace plus minus hit 44px on coarse pointers", function () {
  assert.match(css, /@media \(pointer: coarse\) \{\s*\.rail-ws-btn \{ min-width: 44px; min-height: 44px; \}/);
});

test("config file picker has a visible label", function () {
  assert.match(html, /<label for="config-editor-file">File<\/label>/);
});

test("attaching an image does not wipe the plan/research hint", function () {
  const attach = readFileSync(join(here, "attachments.js"), "utf8");
  const app = readFileSync(join(here, "../app.js"), "utf8");
  assert.doesNotMatch(attach, /els\.hint\.textContent/);
  assert.match(attach, /onAttachmentsChange/);
  assert.match(app, /image attached/);
  assert.match(app, /onAttachmentsChange = updateComposerModeHint/);
});

test("toasts expose a visible dismiss control", function () {
  assert.match(uiSrc, /className = "toast-dismiss"/);
  assert.match(uiSrc, /dismiss\.textContent = "Dismiss"/);
  assert.match(css, /\.toast-dismiss\s*\{/);
});

test("required field labels are marked in CSS", function () {
  assert.match(css, /label:has\(\+ input\[required\]\)::after/);
});

test("parseCssColor reads rgb and hex", async function () {
  const { parseCssColor, cssColorMix, cssColorAlpha } = await import("./utils.js");
  assert.deepEqual(parseCssColor("rgb(11, 87, 208)"), [11, 87, 208]);
  assert.deepEqual(parseCssColor("#0b57d0"), [11, 87, 208]);
  assert.equal(cssColorAlpha("rgb(10, 20, 30)", 0.5), "rgba(10,20,30,0.5)");
  assert.equal(cssColorMix("rgb(0, 0, 0)", "rgb(100, 0, 0)", 0.5), "rgb(50,0,0)");
});

test("knowledge search hits open the matching collection", function () {
  const src = readFileSync(join(here, "../features/knowledge.js"), "utf8");
  assert.match(src, /openCollection\(h\.collection_id,\s*h\.doc_id\)/);
  assert.match(src, /className="secondary search-hit knowledge-hit"/);
  assert.match(src, /function openCollection\(id, docId\)/);
});

test("knowledge deep link opens the real collection view", function () {
  const app = readFileSync(join(here, "../app.js"), "utf8");
  const kb = readFileSync(join(here, "../features/knowledge.js"), "utf8");
  assert.doesNotMatch(app, /knowledge-preview/);
  assert.match(kb, /_pendingKnowledgeId/);
  assert.match(kb, /Show all/);
});

test("tools filter empty offers to clear the query", function () {
  const src = readFileSync(join(here, "tools.js"), "utf8");
  assert.match(src, /No tool matches “" \+ s\.filter \+ "”/);
  assert.match(src, /Clear filter/);
});

test("prompts filter empty offers to clear the query", function () {
  const src = readFileSync(join(here, "../features/prompts.js"), "utf8");
  assert.match(src, /Clear filter/);
});

test("rail title-filter empty offers to clear the query", function () {
  const app = readFileSync(join(here, "../app.js"), "utf8");
  assert.match(app, /No title matches/);
  assert.match(app, /clear the filter/);
});

test("board filter empty offers to clear the filters", function () {
  assert.match(html, /id="board-filter-empty"/);
  assert.match(html, /id="board-filter-clear"/);
  const src = readFileSync(join(here, "../features/board.js"), "utf8");
  assert.match(src, /function clearBoardFilters/);
  assert.match(src, /No cards in this lane match the filters/);
});

test("knowledge search empty offers to clear the query", function () {
  const src = readFileSync(join(here, "../features/knowledge.js"), "utf8");
  assert.match(src, /No documents mention/);
  assert.match(src, /Clear search/);
});

test("compare and arena empty lists sit in the picker, not only the status line", function () {
  const compare = readFileSync(join(here, "../features/compare.js"), "utf8");
  const arena = readFileSync(join(here, "../features/arena.js"), "utf8");
  assert.match(compare, /No comparisons yet\. Run one with /);
  assert.match(arena, /No matches yet\. Run one with /);
});

test("Rooms does not steal Ctrl+K from the Jump palette", function () {
  const app = readFileSync(join(here, "../app.js"), "utf8");
  assert.doesNotMatch(app, /slack-quick-switch/);
  assert.doesNotMatch(app, /Switch to channel or DM/);
  const pal = readFileSync(join(here, "palette.js"), "utf8");
  assert.match(pal, /e\.key === "k" \|\| e\.key === "K"/);
  assert.match(html, /id="palette-open"[^>]*title="Jump to anything \(Ctrl\+K\)"/);
});

test("rooms filter and message search are search inputs", function () {
  assert.match(html, /type="search" id="chat-room-filter"/);
  assert.match(html, /type="search" id="chat-search-input"/);
  const app = readFileSync(join(here, "../app.js"), "utf8");
  assert.match(app, /chat-room-filter-empty/);
  assert.match(app, /No channel matches/);
});

test("steer row has a visible label", function () {
  assert.match(html, /<label for="steer-input">Steer this turn<\/label>/);
});

test("empty Run control explains the disabled state", function () {
  const submit = html.slice(html.indexOf('id="submit"'), html.indexOf('id="submit"') + 220);
  assert.match(submit, /title="Write a task first"/);
  const src = readFileSync(join(here, "modelpicker.js"), "utf8");
  assert.match(src, /Write a task first/);
});

test("empty Rooms Send control explains the disabled state", function () {
  const send = html.slice(html.indexOf('id="chat-send"'), html.indexOf('id="chat-send"') + 220);
  assert.match(send, /title="Write a message first"/);
  const app = readFileSync(join(here, "../app.js"), "utf8");
  assert.match(app, /function syncChatSend/);
  assert.match(app, /Write a message first/);
  assert.match(app, /Pick a channel first/);
});

test("required marker covers a required input nested in its label", function () {
  assert.match(css, /label:has\(> input\[required\]\)::after/);
  assert.match(html, /id="models-edit-provider"[^>]*required/);
  assert.match(html, /id="models-edit-model"[^>]*required/);
});

test("Search field names conversations, not Find", function () {
  assert.match(html, /<label for="search-q">Search conversations<\/label>/);
});

test("Board create goal is the primary action", function () {
  assert.match(html, /id="goal-add"[^>]*class="primary"|class="primary"[^>]*id="goal-add"/);
  assert.match(html, /id="board-empty-create"[^>]*class="primary"|class="primary"[^>]*id="board-empty-create"/);
  assert.match(html, /id="board-empty-create"[^>]*>New goal</);
});

test("create and save forms use a primary CTA", function () {
  assert.match(html, /id="knowledge-create"[^>]*class="primary"|class="primary"[^>]*id="knowledge-create"/);
  assert.match(html, /id="prompts-create"[^>]*class="primary"|class="primary"[^>]*id="prompts-create"/);
  assert.match(html, /id="workspace-new-save"[^>]*class="primary"|class="primary"[^>]*id="workspace-new-save"/);
  assert.match(html, /id="text-prompt-save"[^>]*class="primary"|class="primary"[^>]*id="text-prompt-save"/);
});

test("Settings surfaces the Enter-sends composer preference", function () {
  assert.match(html, /id="settings-enter-sends"/);
  assert.match(html, /Enter sends, Shift\+Enter makes a new line/);
});

test("empty log picker names the empty state", function () {
  const src = readFileSync(join(here, "logs.js"), "utf8");
  assert.match(src, /No log files yet/);
  assert.match(src, /logSelect\.disabled = true/);
});

test("rooms composer does not park a leftover hash in the text field", function () {
  assert.doesNotMatch(css, /\.chat-composer::before\s*\{[^}]*content:\s*"#"/);
  assert.match(css, /\.chat-composer\s*\{[^}]*flex-direction:\s*column/);
});

test("rooms message actions stay visible without hover", function () {
  assert.match(css, /@media \(hover: none\)/);
  assert.match(css, /\.chat-msg:not\(\.chat-msg-deleted\) \.chat-actions/);
});

test("rooms channel rows are 44px on coarse pointers", function () {
  assert.match(css, /\.slack-room-item/);
  assert.match(css, /pointer: coarse[\s\S]*\.slack-room-item/);
});

test("System view has an on-page jump list", function () {
  assert.match(html, /class="system-jump"/);
  assert.match(html, /data-system-jump="settings-section"/);
  assert.match(html, /data-system-jump="mcp-section"/);
  assert.match(html, /id="system-progress"/);
  assert.match(html, /id="system-logs"/);
});

test("Run shape summary names the modes that are on", function () {
  const app = readFileSync(join(here, "../app.js"), "utf8");
  assert.match(app, /function syncRunShape/);
  assert.match(app, /bits\.join\(" · "\)/);
  assert.match(app, /el\.worktreeMode\.addEventListener\("change", updateComposerModeHint\)/);
  assert.match(css, /\.run-shape\[data-active="true"\]/);
});

test("rail Watch and Set up folds persist across loads", function () {
  const app = readFileSync(join(here, "../app.js"), "utf8");
  assert.match(app, /clanker\.railFolds/);
  assert.match(app, /function restoreRailFolds/);
  assert.match(app, /restoreRailFolds\(\)/);
});

test("session Delete explains it is permanent", function () {
  const del = html.slice(html.indexOf('id="session-delete"'), html.indexOf('id="session-delete"') + 220);
  assert.match(del, /Permanently delete this conversation/);
});

test("Search stays disabled until the query is long enough", function () {
  const src = readFileSync(join(here, "../features/search.js"), "utf8");
  assert.match(src, /btn\.disabled = on \|\| tooShort/);
  assert.match(src, /Type at least /);
});

test("knowledge hint tells the reader to tick a collection", function () {
  assert.match(html, /Tick a collection to include its documents in the next chat/);
  assert.doesNotMatch(html, /inject documents/);
  const kb = readFileSync(join(here, "../features/knowledge.js"), "utf8");
  assert.match(kb, /Tick a collection to include its documents in the next chat/);
});

test("Board new-goal form sits behind a disclosure", function () {
  assert.match(html, /id="board-create-fold"/);
  const fold = html.slice(html.indexOf('id="board-create-fold"'), html.indexOf('id="card-form"'));
  assert.match(fold, /id="goal-form"/);
});

test("rooms copy uses the shared copy feedback helper", function () {
  const app = readFileSync(join(here, "../app.js"), "utf8");
  assert.match(app, /copyText\(m\.text, copyBtn, "Copy"/);
  assert.match(app, /function syncChatLogEmpty/);
});

test("failed list loads keep a visible retry in the panel", function () {
  assert.match(uiSrc, /export function showLoadError/);
  assert.match(uiSrc, /btn\.textContent = "Try again"/);
  const schedule = readFileSync(join(here, "../features/schedule.js"), "utf8");
  const prompts = readFileSync(join(here, "../features/prompts.js"), "utf8");
  const knowledge = readFileSync(join(here, "../features/knowledge.js"), "utf8");
  const plugins = readFileSync(join(here, "plugins.js"), "utf8");
  const tools = readFileSync(join(here, "tools.js"), "utf8");
  const board = readFileSync(join(here, "../features/board.js"), "utf8");
  const search = readFileSync(join(here, "../features/search.js"), "utf8");
  const compare = readFileSync(join(here, "../features/compare.js"), "utf8");
  const arena = readFileSync(join(here, "../features/arena.js"), "utf8");
  const app = readFileSync(join(here, "../app.js"), "utf8");
  const logs = readFileSync(join(here, "logs.js"), "utf8");
  assert.match(schedule, /showLoadError\(byId\("schedule-list"\)/);
  assert.match(prompts, /showLoadError\(document\.getElementById\("prompts-list"\)/);
  assert.match(knowledge, /showLoadError\(document\.getElementById\("knowledge-list"\)/);
  assert.match(plugins, /showLoadError\(_el\.webuiPlugins/);
  assert.match(tools, /showLoadError\(_el\.tools/);
  assert.match(tools, /showLoadError\(box, msg, loadWorkflows\)/);
  assert.match(tools, /showLoadError\(box, msg, loadSkills\)/);
  assert.match(board, /showLoadError\(el\.board/);
  assert.match(board, /el\.boardEmpty\.hidden = !boardLoaded \|\| s\.cards\.length > 0/);
  assert.match(search, /Try again/);
  assert.match(compare, /showLoadError\(byId\("compare-list"\)/);
  assert.match(arena, /showLoadError\(byId\("arena-list"\)/);
  assert.match(app, /showLoadError\(el\.usage/);
  assert.match(app, /showLoadError\(list, msg, load\)/);
  assert.match(app, /function syncMcpTransportFields/);
  assert.match(app, /stdio needs a command to spawn/);
  assert.match(html, /data-mcp-for="stdio"/);
  assert.match(html, /data-mcp-for="http"/);
  assert.match(css, /\.models-edit-form label\[hidden\] \{ display: none; \}/);
  assert.match(logs, /els\.logView\.textContent = msg/);
  assert.match(app, /Could not load rooms: /);
  assert.match(app, /Try again/);
  assert.match(app, /Channels unavailable/);
  const roomsCatch = app.slice(app.indexOf("Could not load rooms: "));
  assert.match(roomsCatch, /loadChatRooms/);
  const kb = readFileSync(join(here, "../features/knowledge.js"), "utf8");
  assert.match(kb, /Could not open this collection/);
  assert.match(kb, /openCollection\(id, docId\)/);
  assert.match(kb, /Search failed: /);
  assert.match(kb, /retry\.addEventListener\("click",doSearch\)/);
  const activity = readFileSync(join(here, "../../plugins/activity/app.js"), "utf8");
  assert.match(activity, /function drawFailure/);
  assert.match(activity, /Try again/);
  assert.match(activity, /api\.el\("button", "activity-card", label\)/);
});

test("templates and skills say when none are on file", function () {
  const tools = readFileSync(join(here, "tools.js"), "utf8");
  assert.match(tools, /No templates on file/);
  assert.match(tools, /No skills on file/);
  assert.doesNotMatch(tools, /box\.hidden = list\.length === 0/);
});

test("phone fields stay at 16px so iOS does not zoom on focus", function () {
  assert.match(css, /iOS Safari zooms the page when a focused field is under 16px/);
  assert.match(css, /@media \(max-width: 40rem\) \{[\s\S]*?\.composer textarea \{\s*font-size:\s*16px/);
  // These selectors set a smaller size after the page-wide guard. A later
  // 40rem block has to put 16px back or iOS Safari zooms the page on focus.
  const rail = css.lastIndexOf(".rail input[type=\"search\"] { font-size: 16px; }");
  const railDesktop = css.indexOf(".rail input[type=\"search\"] { width: 100%");
  assert.ok(rail > railDesktop, "phone rail search must override the 12px desktop size");
  const add = css.lastIndexOf(".board-quick-add .board-add-form textarea { font-size: 16px; }");
  const addDesktop = css.indexOf(".board-quick-add .board-add-form textarea {\n  width: 100%");
  assert.ok(add > addDesktop, "phone quick-add must override the 13px desktop size");
  const roomsDesktop = css.indexOf(".slack-composer-row input[type=\"text\"] {\n");
  const roomsPhone = css.lastIndexOf(".slack-composer-row input[type=\"text\"],");
  assert.ok(roomsDesktop >= 0 && roomsPhone > roomsDesktop, "phone Rooms composer must override the 13px desktop size");
  const wsDesktop = css.indexOf(".rail-workspace-bar select {\n");
  const wsPhone = css.lastIndexOf(".rail-workspace-bar select,");
  assert.ok(wsDesktop >= 0 && wsPhone > wsDesktop, "phone workspace picker must override the 12px desktop size");
});

test("accent pill is primary/#submit only, not every unmarked button", function () {
  assert.doesNotMatch(
    css,
    /button:where\(:not\(\.pf-v6-c-button\)\)\s*\{[^}]*background:\s*var\(--accent\)/,
  );
  const primary = ruleBody("button.primary:where(:not(.pf-v6-c-button)),\n#submit:where(:not(.pf-v6-c-button))");
  assert.match(primary, /background:\s*var\(--accent\)/);
});

test("Search and Create channel use a primary CTA", function () {
  assert.match(html, /id="search-go"[^>]*class="primary"|class="primary"[^>]*id="search-go"/);
  assert.match(html, /id="search-go"[^>]*>Search conversations</);
  assert.match(html, /id="chat-create-confirm"[^>]*class="primary"|class="primary"[^>]*id="chat-create-confirm"/);
  assert.match(html, /id="chat-create-confirm"[^>]*>Create channel</);
  assert.match(html, /id="config-editor-save"[^>]*class="primary"|class="primary"[^>]*id="config-editor-save"/);
  const app = readFileSync(join(here, "../app.js"), "utf8");
  assert.match(app, /btn\.className = "primary"/);
  assert.match(app, /btn\.textContent = "Create a channel"/);
});

test("Fleet empty roster points at System Config instead of the phonebook", function () {
  const src = readFileSync(join(here, "../features/fleet.js"), "utf8");
  assert.match(src, /Add a peer in System → Config/);
  assert.match(src, /Open Config/);
  assert.match(src, /function navToSystemConfig/);
  assert.match(src, /Open Rooms/);
  assert.match(src, /Open Chat/);
  assert.match(src, /function navToChat/);
  assert.match(src, /"primary", "Open Config"/);
  assert.doesNotMatch(src, /phonebook/);
  assert.doesNotMatch(src, /\[\[peers\]\]/);
});

test("Activity empty state offers to open the board", function () {
  const src = readFileSync(join(here, "../../plugins/activity/app.js"), "utf8");
  assert.match(src, /Nothing recorded yet/);
  assert.match(src, /Open board/);
  assert.match(src, /"primary", "Open board"/);
  assert.match(src, /api\.showView\("board"\)/);
  const css = readFileSync(join(here, "../../plugins/activity/app.css"), "utf8");
  assert.match(css, /@media \(max-width: 40rem\) \{\s*\.activity-card \{ min-height: 44px; \}/);
});

test("Knowledge add-document is a primary CTA", function () {
  const src = readFileSync(join(here, "../features/knowledge.js"), "utf8");
  assert.match(src, /submit\.className="primary"/);
  assert.match(src, /submit\.textContent="Add document"/);
  assert.match(src, /start\.className="primary"/);
  assert.match(src, /start\.textContent="Add collection"/);
});

test("rooms own-message actions are labeled and report a failed write", function () {
  const app = readFileSync(join(here, "../app.js"), "utf8");
  assert.match(app, /editBtn\.textContent = "Edit"/);
  assert.match(app, /delBtn\.textContent = "Delete"/);
  assert.match(app, /Could not pin that message/);
  assert.match(app, /Could not save the edit/);
  assert.match(app, /Could not delete that message/);
  assert.doesNotMatch(app, /editBtn\.textContent = "✏️"/);
  assert.doesNotMatch(app, /delBtn\.textContent = "🗑️"/);
});
