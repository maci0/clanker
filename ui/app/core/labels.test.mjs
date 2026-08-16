import assert from "node:assert/strict";
import test from "node:test";
import { compareToolCategories, toolCategoryLabel } from "./labels.js";

test("tool category labels are the Tools section headings", function () {
  assert.equal(toolCategoryLabel("kanban"), "Kanban");
  assert.notEqual(toolCategoryLabel("kanban"), "Board");
  assert.equal(toolCategoryLabel("knowledge"), "Knowledge");
  assert.equal(toolCategoryLabel("harness"), "Harness");
  assert.equal(toolCategoryLabel("chat"), "Chat");
  assert.equal(toolCategoryLabel(""), "Other");
  assert.equal(toolCategoryLabel("other"), "Other");
  assert.equal(toolCategoryLabel("custom"), "Custom");
});

test("tool categories sort work-first, unknown before other", function () {
  const cats = ["other", "harness", "knowledge", "chat", "code", "invented"];
  cats.sort(compareToolCategories);
  assert.deepEqual(cats, ["code", "chat", "knowledge", "harness", "invented", "other"]);
});
