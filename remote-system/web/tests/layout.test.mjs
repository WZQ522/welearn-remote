import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const html = await readFile(path.join(root, "index.html"), "utf8");
const css = await readFile(path.join(root, "styles.css"), "utf8");
const app = await readFile(path.join(root, "app.js"), "utf8");

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

test("deployment keeps the public page HTTPS-only and pins the external icon bundle", () => {
  assert.match(html, /name="referrer" content="no-referrer"/);
  assert.match(html, /http-equiv="Content-Security-Policy"/);
  assert.match(html, /integrity="sha384-[A-Za-z0-9+/=]+"/);
  assert.match(html, /crossorigin="anonymous"/);
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

test("active tasks expose cancel while only terminal tasks expose delete", () => {
  assert.match(html, /class="danger-button cancel-button"/);
  assert.match(html, /class="danger-button delete-button"/);
  assert.match(app, /api\.cancelMine\(submission\.id/);
  assert.match(app, /api\.retryMine\(submission\.id/);
  assert.match(app, /api\.removeMine\(submission\.id/);
  assert.match(app, /remove\.hidden = \["pending", "processing"\]\.includes\(submission\.status\)/);
});

test("signed-in users have a separate wallet profile with recharge and ledger views", () => {
  assert.match(html, /id="profileBand"/);
  assert.match(html, /id="walletBalance"/);
  assert.match(html, /id="rechargeForm"/);
  assert.match(html, /id="rechargeRequestList"/);
  assert.match(html, /id="walletTransactionList"/);
  assert.match(html, /U校园[^<]*¥0\.30/);
  assert.match(html, /WeLearn[^<]*¥0\.15/);
  assert.match(app, /api\.getMyProfile\(/);
  assert.match(app, /api\.createRechargeRequest\(/);
});

test("admin console can review recharge requests and adjust account balances", () => {
  assert.match(html, /id="adminRechargeList"/);
  assert.match(app, /api\.adminAdjustRemoteUserBalance\(/);
  assert.match(app, /api\.adminDecideRechargeRequest\(/);
});

test("admin console shows queue capacity and online agents", () => {
  assert.match(html, /id="adminQueueMetrics"/);
  assert.match(app, /api\.adminGetQueueMetrics\(/);
  assert.match(app, /在线 Agent/);
  assert.match(css, /\.queue-metrics-grid/);
});

test("every account task reserves a stable row for recognized unit count and estimated charge", () => {
  assert.match(html, /class="unit-summary-row"/);
  assert.match(html, /class="available-unit-count"/);
  assert.match(html, /class="selected-unit-count"/);
  assert.match(html, /class="estimated-unit-charge"/);
  assert.match(app, /submissionUnitSummary\(submission\)/);
  assert.match(css, /\.unit-summary-row/);
});

test("task history is account-scoped instead of device-scoped", () => {
  assert.doesNotMatch(html, /id="clearButton"/);
  assert.match(html, /id="taskList"/);
  assert.match(html, /当前账户/);
  assert.match(app, /groupSubmissions\(submissions\)/);
  assert.match(app, /className = "batch-task-list"/);
  assert.match(app, /api\.submitBatch\(/);
});

test("overlapping refreshes cannot replace newer task state with an older response", () => {
  assert.match(app, /let refreshRequestID = 0/);
  assert.match(app, /const requestID = \+\+refreshRequestID/);
  assert.match(app, /requestID !== refreshRequestID/);
});

test("every batch renders an execution score distribution module", () => {
  assert.match(app, /batchScoreSummary/);
  assert.match(app, /执行完成总分/);
  assert.match(app, /className = "batch-score-summary"/);
  assert.match(css, /\.score-overview-grid/);
  assert.match(css, /\.score-band-grid/);
  assert.match(css, /\.score-overview-grid, \.score-band-grid \{ grid-template-columns: repeat\(2, minmax\(0, 1fr\)\); \}/);
});

test("design avoids gradients, decorative orbs, and viewport-scaled type", () => {
  assert.doesNotMatch(css, /gradient\s*\(/i);
  assert.doesNotMatch(`${html}\n${css}`, /\borb\b/i);
  assert.doesNotMatch(css, /font-size\s*:\s*[^;]*(vw|vmin|vmax)/i);
  assert.doesNotMatch(css, /letter-spacing\s*:\s*-/i);
});
