import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const html = await readFile(path.join(root, "index.html"), "utf8");
const css = await readFile(path.join(root, "styles.css"), "utf8");

test("mobile breakpoint keeps the batch form and actions readable", () => {
  assert.match(css, /@media \(max-width: 700px\)/);
  assert.match(css, /\.form-footer \{ align-items: stretch; flex-direction: column; \}/);
  assert.match(css, /\.task-card footer \{ align-items: stretch; flex-direction: column; \}/);
});

test("interactive commands use icon-backed buttons", () => {
  for (const icon of ["refresh-cw", "send", "rotate-ccw", "x", "trash-2", "log-in", "user-plus", "log-out"]) {
    assert.match(html, new RegExp(`data-lucide="${icon}"`));
  }
});

test("account access requires a username, password, and invitation code", () => {
  assert.match(html, /id="loginForm"/);
  assert.match(html, /id="loginView"/);
  assert.match(html, /id="registerForm"/);
  assert.match(html, /id="registerView"[^>]*hidden/);
  assert.match(html, /id="showRegisterLink"[^>]*>去注册</);
  assert.match(html, /id="invitationCode"/);
  assert.match(html, /id="submitBand"[^>]*hidden/);
  assert.match(html, /id="tasksBand"[^>]*hidden/);
  assert.match(html, /id="submitButton"[^>]*disabled/);
});

test("admin console exposes invitation status and registered accounts", () => {
  assert.match(html, /id="adminCodeList"/);
  assert.match(html, /id="adminAvailableCount"/);
  assert.match(html, /id="adminUsedCount"/);
  assert.match(html, /id="adminUserList"/);
  assert.match(html, /id="adminUserCount"/);
});

test("submission form uses the original batch text contract", () => {
  assert.match(html, /id="rawText"/);
  assert.match(html, /平台 账号 密码/);
  assert.doesNotMatch(html, /输入 JSON|任务类型|任务名称/);
  assert.ok(html.indexOf("class=\"format-note\"") < html.indexOf("id=\"rawText\""));
});

test("every task card exposes independent cancel and delete actions", () => {
  assert.match(html, /class="danger-button cancel-button"/);
  assert.match(html, /class="danger-button delete-button"/);
});

test("design avoids gradients, decorative orbs, and viewport-scaled type", () => {
  assert.doesNotMatch(css, /gradient\s*\(/i);
  assert.doesNotMatch(`${html}\n${css}`, /\borb\b/i);
  assert.doesNotMatch(css, /font-size\s*:\s*[^;]*(vw|vmin|vmax)/i);
  assert.doesNotMatch(css, /letter-spacing\s*:\s*-/i);
});
