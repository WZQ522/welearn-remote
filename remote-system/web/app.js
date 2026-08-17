import { randomToken, SupabaseSubmissionApi } from "./api.js?v=account-tasks-v1";
import { batchScoreSummary, batchStatus, groupSubmissions } from "./task-model.js?v=account-scores-v1";

const CLIENT_KEY = "unified-remote-client-id-v1";
const AUTH_KEY = "unified-remote-auth-v1";

const elements = {
  accountTitle: document.querySelector("#accountTitle"),
  authForms: document.querySelector("#authForms"),
  loginView: document.querySelector("#loginView"),
  registerView: document.querySelector("#registerView"),
  showRegisterLink: document.querySelector("#showRegisterLink"),
  showLoginLink: document.querySelector("#showLoginLink"),
  loginForm: document.querySelector("#loginForm"),
  loginUsername: document.querySelector("#loginUsername"),
  loginPassword: document.querySelector("#loginPassword"),
  loginButton: document.querySelector("#loginButton"),
  registerForm: document.querySelector("#registerForm"),
  registerUsername: document.querySelector("#registerUsername"),
  registerPassword: document.querySelector("#registerPassword"),
  invitationCode: document.querySelector("#invitationCode"),
  registerButton: document.querySelector("#registerButton"),
  authMessage: document.querySelector("#authMessage"),
  adminBand: document.querySelector("#adminBand"),
  issueInvitationButton: document.querySelector("#issueInvitationButton"),
  adminCodeList: document.querySelector("#adminCodeList"),
  adminAvailableCount: document.querySelector("#adminAvailableCount"),
  adminUsedCount: document.querySelector("#adminUsedCount"),
  adminUserCount: document.querySelector("#adminUserCount"),
  adminUserList: document.querySelector("#adminUserList"),
  adminMessage: document.querySelector("#adminMessage"),
  userSession: document.querySelector("#userSession"),
  loggedUsername: document.querySelector("#loggedUsername"),
  logoutButton: document.querySelector("#logoutButton"),
  form: document.querySelector("#submissionForm"),
  rawText: document.querySelector("#rawText"),
  lineCount: document.querySelector("#lineCount"),
  submit: document.querySelector("#submitButton"),
  message: document.querySelector("#formMessage"),
  connection: document.querySelector("#connectionText"),
  refresh: document.querySelector("#refreshButton"),
  submitBand: document.querySelector("#submitBand"),
  tasksBand: document.querySelector("#tasksBand"),
  list: document.querySelector("#taskList"),
  count: document.querySelector("#taskCount"),
  empty: document.querySelector("#emptyState"),
  template: document.querySelector("#taskTemplate"),
};

let api = null;
let refreshTimer = null;
let auth = loadAuth();
let authView = window.location.hash === "#register" ? "register" : "login";
const submissionState = new Map();

function countLines(value) {
  return value.split(/\r?\n/).filter(line => line.trim()).length;
}

function loadAuth() {
  try {
    const value = JSON.parse(localStorage.getItem(AUTH_KEY) || "null");
    return value?.sessionToken && value?.username
      ? { sessionToken: value.sessionToken, username: value.username, isAdmin: value.isAdmin === true }
      : null;
  } catch {
    return null;
  }
}

function saveAuth(value) {
  auth = value;
  if (value) localStorage.setItem(AUTH_KEY, JSON.stringify(value));
  else localStorage.removeItem(AUTH_KEY);
  updateAuthUI();
}

function clientId() {
  let value = localStorage.getItem(CLIENT_KEY);
  if (!value) {
    value = crypto.randomUUID();
    localStorage.setItem(CLIENT_KEY, value);
  }
  return value;
}

function friendlyError(error) {
  const message = String(error?.message || error || "请求失败");
  const messages = [
    ["username_taken", "用户名已存在，请换一个用户名"],
    ["invalid_username", "用户名需为 3-64 位字母、数字、下划线、点、@ 或短横线"],
    ["invalid_password", "密码需为 8-128 位"],
    ["invalid_invitation_code", "邀请码无效"],
    ["invitation_code_used", "邀请码已使用"],
    ["invitation_code_expired", "邀请码已过期，请使用当天生成的邀请码"],
    ["invalid_credentials", "用户名或密码不正确"],
    ["admin_required", "需要管理员权限"],
    ["admin_target_protected", "管理员账号受保护，不能操作"],
    ["admin_self_protected", "不能删除当前登录的管理员账号"],
    ["remote_user_not_found", "账号不存在或已被删除"],
    ["login_required", "登录状态已失效，请重新登录"],
  ];
  return messages.find(([code]) => message.includes(code))?.[1] || message;
}

function isAuthError(error) {
  return /login_required|invalid session|session/i.test(String(error?.message || ""));
}

function statusInfo(submission) {
  if (submission.status === "canceled") return { label: "已取消", tone: "failed" };
  if (submission.status === "failed" || submission.execution_status === "failed") return { label: "失败", tone: "failed" };
  if (submission.execution_status === "needs_action") return { label: "需处理", tone: "warning" };
  if (submission.execution_status === "partial") return { label: "部分完成", tone: "warning" };
  if (submission.execution_status === "completed") return { label: "已完成", tone: "completed" };
  if (submission.status === "processing" || submission.execution_status === "running") return { label: "执行中", tone: "processing" };
  return { label: "等待电脑", tone: "pending" };
}

function progressInfo(submission) {
  const total = Math.max(0, Number(submission.task_total || submission.line_count || 0));
  const completed = Math.max(0, Number(submission.task_completed || 0));
  const failed = Math.max(0, Number(submission.task_failed || 0));
  const settled = Math.min(total, completed + failed);
  return {
    total,
    completed,
    failed,
    settled,
    percent: total ? Math.round((settled / total) * 100) : 0,
  };
}

function messageFor(submission) {
  if (submission.result_message) return submission.result_message;
  if (submission.status === "pending") return "任务已保存在云端，等待电脑 Agent 领取。";
  if (submission.status === "processing") {
    return submission.cancel_requested ? "已请求取消，等待电脑确认。" : "电脑已领取，统一刷课助手正在执行。";
  }
  if (submission.status === "failed") return submission.error_message || "本地程序执行失败。";
  if (submission.status === "canceled") return "任务已取消。";
  return "执行结果已上传。";
}

function formatTime(value) {
  if (!value) return "";
  return new Intl.DateTimeFormat("zh-CN", { dateStyle: "short", timeStyle: "short" }).format(new Date(value));
}

function showAuthView(view, { updateHistory = false } = {}) {
  authView = view === "register" ? "register" : "login";
  elements.loginView.hidden = authView !== "login";
  elements.registerView.hidden = authView !== "register";
  if (!auth) elements.accountTitle.textContent = authView === "register" ? "注册" : "登录";
  if (updateHistory) {
    const url = new URL(window.location.href);
    url.hash = authView === "register" ? "register" : "";
    window.history.pushState(null, "", url);
  }
}

function updateAuthUI() {
  const loggedIn = Boolean(auth);
  elements.authForms.hidden = loggedIn;
  elements.userSession.hidden = !loggedIn;
  elements.accountTitle.textContent = loggedIn ? "账户" : authView === "register" ? "注册" : "登录";
  elements.loggedUsername.textContent = loggedIn ? auth.username : "";
  elements.submitBand.hidden = !loggedIn;
  elements.tasksBand.hidden = !loggedIn;
  elements.adminBand.hidden = !loggedIn || !auth.isAdmin;
  elements.submit.disabled = !api || !loggedIn;
  elements.refresh.disabled = !api || !loggedIn;
  elements.loginButton.disabled = !api;
  elements.registerButton.disabled = !api;
  if (!loggedIn) {
    showAuthView(authView);
    clearTimeout(refreshTimer);
    elements.connection.textContent = api ? "请登录后查看任务" : "云端尚未配置";
  }
}

function renderAdminCodes(codes) {
  elements.adminCodeList.replaceChildren();
  const availableCount = codes.filter(item => !item.used_at).length;
  const usedCount = codes.length - availableCount;
  elements.adminAvailableCount.textContent = `可用邀请码 ${availableCount}`;
  elements.adminUsedCount.textContent = `今日已使用 ${usedCount}`;
  if (!codes.length) {
    elements.adminCodeList.textContent = "今天还没有邀请码";
    return;
  }
  for (const item of codes) {
    const row = document.createElement("div");
    row.className = `admin-code-row${item.used_at ? " used" : ""}`;
    const code = document.createElement("code");
    code.textContent = item.code;
    const details = document.createElement("div");
    details.className = "admin-code-details";
    const state = document.createElement("strong");
    state.className = `admin-state ${item.used_at ? "used" : "available"}`;
    state.textContent = item.used_at ? "已使用" : "未使用";
    details.append(state);
    if (item.used_at) {
      const usage = document.createElement("span");
      usage.textContent = `${item.used_username || "账号已删除"} · ${formatTime(item.used_at)}`;
      details.append(usage);
    }
    row.append(code, details);
    elements.adminCodeList.append(row);
  }
}

function renderAdminUsers(users) {
  elements.adminUserList.replaceChildren();
  elements.adminUserCount.textContent = `注册账号 ${users.length}`;
  if (!users.length) {
    elements.adminUserList.textContent = "还没有注册账号";
    return;
  }
  for (const item of users) {
    const row = document.createElement("div");
    row.className = "admin-user-row";
    const identity = document.createElement("div");
    identity.className = "admin-user-identity";
    const username = document.createElement("strong");
    username.textContent = item.username;
    const role = document.createElement("span");
    role.textContent = item.is_admin ? "管理员" : "普通账号";
    identity.append(username, role);
    const activity = document.createElement("div");
    activity.className = "admin-user-activity";
    const created = document.createElement("span");
    created.textContent = `注册 ${formatTime(item.created_at)}`;
    const lastLogin = document.createElement("span");
    lastLogin.textContent = item.last_login_at ? `最近登录 ${formatTime(item.last_login_at)}` : "尚未登录";
    activity.append(created, lastLogin);
    const actions = document.createElement("div");
    actions.className = "admin-user-actions";
    if (item.is_admin) {
      const protectedLabel = document.createElement("span");
      protectedLabel.className = "admin-protected-label";
      protectedLabel.textContent = "管理员账号受保护";
      actions.append(protectedLabel);
    } else {
      const resetButton = document.createElement("button");
      resetButton.className = "secondary-button admin-action-button";
      resetButton.type = "button";
      resetButton.title = "重置密码为 11111111";
      resetButton.innerHTML = '<i data-lucide="key-round"></i><span>重置密码</span>';
      resetButton.addEventListener("click", () => resetRemoteUserPassword(item));
      const deleteButton = document.createElement("button");
      deleteButton.className = "danger-button admin-action-button";
      deleteButton.type = "button";
      deleteButton.title = "删除账号";
      deleteButton.innerHTML = '<i data-lucide="trash-2"></i><span>删除账号</span>';
      deleteButton.addEventListener("click", () => deleteRemoteUser(item));
      actions.append(resetButton, deleteButton);
    }
    row.append(identity, activity, actions);
    elements.adminUserList.append(row);
  }
  window.lucide?.createIcons();
}

async function resetRemoteUserPassword(user) {
  if (!auth || !confirm(`确定将账号 ${user.username} 的密码重置为 11111111 吗？该账号需要重新登录。`)) return;
  elements.adminMessage.textContent = `正在重置 ${user.username} 的密码`;
  try {
    await api.adminResetRemoteUserPassword(auth.sessionToken, user.id);
    await refreshAdminConsole({ successMessage: `${user.username} 的密码已重置为 11111111` });
  } catch (error) {
    elements.adminMessage.textContent = `重置失败：${friendlyError(error)}`;
  }
}

async function deleteRemoteUser(user) {
  if (!auth || !confirm(`确定删除账号 ${user.username} 吗？该账号的任务和登录会话也会被删除。`)) return;
  elements.adminMessage.textContent = `正在删除 ${user.username}`;
  try {
    await api.adminDeleteRemoteUser(auth.sessionToken, user.id);
    await refreshAdminConsole({ successMessage: `账号 ${user.username} 已删除` });
  } catch (error) {
    elements.adminMessage.textContent = `删除失败：${friendlyError(error)}`;
  }
}

async function refreshAdminConsole({ successMessage = "" } = {}) {
  if (!api || !auth?.isAdmin) return;
  const activeSession = auth.sessionToken;
  const [codesResult, usersResult] = await Promise.allSettled([
    api.adminListInvitationCodes(activeSession),
    api.adminListRemoteUsers(activeSession),
  ]);
  if (auth?.sessionToken !== activeSession) return;

  const errors = [];
  if (codesResult.status === "fulfilled") {
    renderAdminCodes(Array.isArray(codesResult.value) ? codesResult.value : []);
  } else {
    errors.push(`邀请码：${friendlyError(codesResult.reason)}`);
  }
  if (usersResult.status === "fulfilled") {
    renderAdminUsers(Array.isArray(usersResult.value) ? usersResult.value : []);
  } else {
    errors.push(`注册账号：${friendlyError(usersResult.reason)}`);
  }
  elements.adminMessage.textContent = errors.length
    ? `读取失败：${errors.join("；")}`
    : successMessage;
}

function syncAuthViewFromLocation() {
  if (!auth) showAuthView(window.location.hash === "#register" ? "register" : "login");
}

function renderTask(submission) {
  const status = statusInfo(submission);
  const progress = progressInfo(submission);
  const card = elements.template.content.firstElementChild.cloneNode(true);
  card.dataset.status = status.tone;

  const position = Number(submission.batch_position || 1);
  const batchSize = Number(submission.batch_size || 1);
  const defaultLabel = batchSize > 1 ? `账号任务 ${position}` : `账号任务`;
  card.querySelector(".task-title").textContent = submission.task_label || defaultLabel;
  card.querySelector(".task-time").textContent = batchSize > 1
    ? `第 ${position} / ${batchSize} 项`
    : formatTime(submission.created_at);
  card.querySelector(".status-badge").textContent = status.label;
  card.querySelector(".progress-count").textContent = `进度 ${progress.settled} / ${progress.total}`;
  card.querySelector(".progress-percent").textContent = `${progress.percent}%`;
  card.querySelector(".progress-track").value = progress.percent;
  card.querySelector(".completed-count").textContent = `完成 ${progress.completed}`;
  card.querySelector(".failed-count").textContent = `失败 ${progress.failed}`;
  card.querySelector(".task-message").textContent = messageFor(submission);
  card.querySelector(".attempt-count").textContent = `执行次数 ${submission.attempt_count || 0}`;

  const cancel = card.querySelector(".cancel-button");
  cancel.hidden = !["pending", "processing"].includes(submission.status) || submission.cancel_requested;
  cancel.addEventListener("click", () => cancelSubmission(submission));

  const remove = card.querySelector(".delete-button");
  remove.addEventListener("click", () => deleteSubmission(submission));

  const retry = card.querySelector(".retry-button");
  retry.hidden = !(
    ["failed", "canceled"].includes(submission.status)
    || ["needs_action", "partial", "failed"].includes(submission.execution_status)
  );
  retry.addEventListener("click", () => retrySubmission(submission));
  return card;
}

function batchSummary(items) {
  const total = items.length;
  const finished = items.filter(item => !["pending", "processing"].includes(item.status)).length;
  const failed = items.filter(item => item.status === "failed" || item.execution_status === "failed").length;
  const canceled = items.filter(item => item.status === "canceled").length;
  const parts = [`已结束 ${finished} / ${total}`];
  if (failed) parts.push(`失败 ${failed}`);
  if (canceled) parts.push(`取消 ${canceled}`);
  return parts.join(" · ");
}

function scoreText(value) {
  return Number.isFinite(value) ? Number(value).toFixed(2) : "-";
}

function scoreBandGrid(distribution) {
  const grid = document.createElement("div");
  grid.className = "score-band-grid";
  const bands = [
    ["100分", distribution.score100],
    ["90-99", distribution.score90To99],
    ["80-89", distribution.score80To89],
    ["60-79", distribution.score60To79],
    ["60以下", distribution.scoreBelow60],
  ];
  for (const [label, count] of bands) {
    const item = document.createElement("div");
    const value = document.createElement("strong");
    value.textContent = String(count);
    const caption = document.createElement("span");
    caption.textContent = label;
    item.append(value, caption);
    grid.append(item);
  }
  return grid;
}

function scoreDistributionRow(label, distribution) {
  const row = document.createElement("div");
  row.className = "score-distribution-row";
  const caption = document.createElement("span");
  caption.className = "score-distribution-label";
  caption.textContent = label;
  row.append(caption, scoreBandGrid(distribution));
  return row;
}

function renderBatchScoreSummary(items) {
  const summary = batchScoreSummary(items);
  const section = document.createElement("section");
  section.className = "batch-score-summary";

  const heading = document.createElement("header");
  const title = document.createElement("h4");
  title.innerHTML = '<i data-lucide="chart-no-axes-column"></i><span>执行完成总分</span>';
  const status = document.createElement("p");
  status.textContent = `${summary.statusText} · 计分账号 ${summary.scoredAccountCount} · 无计分 ${summary.unscoredAccountCount}`;
  heading.append(title, status);
  section.append(heading);

  if (summary.averageScore === null) {
    const empty = document.createElement("p");
    empty.className = "score-summary-empty";
    empty.textContent = "暂无真实计分数据";
    section.append(empty);
    return section;
  }

  const overview = document.createElement("div");
  overview.className = "score-overview-grid";
  for (const [label, value] of [
    ["账号平均", summary.averageScore],
    ["最高", summary.highestScore],
    ["最低", summary.lowestScore],
  ]) {
    const metric = document.createElement("div");
    const caption = document.createElement("span");
    caption.textContent = label;
    const score = document.createElement("strong");
    score.textContent = scoreText(value);
    metric.append(caption, score);
    overview.append(metric);
  }
  section.append(overview);
  section.append(scoreDistributionRow("账号分布", summary.accountDistribution));
  section.append(scoreDistributionRow("计分题分布", summary.itemDistribution));
  return section;
}

function render() {
  const submissions = [...submissionState.values()];
  const groups = groupSubmissions(submissions);
  elements.list.replaceChildren();
  elements.count.textContent = `${groups.length} 批 · ${submissions.length} 个账号`;
  elements.empty.hidden = groups.length > 0;

  for (const [index, group] of groups.entries()) {
    const status = batchStatus(group.items);
    const section = document.createElement("section");
    section.className = "batch-group";
    section.dataset.status = status.tone;

    const header = document.createElement("header");
    header.className = "batch-header";
    const identity = document.createElement("div");
    const title = document.createElement("h3");
    title.textContent = `批次 ${groups.length - index} · ${group.items.length} 个账号`;
    const details = document.createElement("p");
    details.textContent = `${formatTime(group.createdAt)} · ${batchSummary(group.items)}`;
    identity.append(title, details);
    const badge = document.createElement("span");
    badge.className = "batch-status-badge";
    badge.textContent = status.label;
    header.append(identity, badge);

    const taskList = document.createElement("div");
    taskList.className = "batch-task-list";
    for (const submission of group.items) taskList.append(renderTask(submission));
    section.append(header, renderBatchScoreSummary(group.items), taskList);
    elements.list.append(section);
  }
  window.lucide?.createIcons();
}

async function refreshSubmissions({ quiet = false } = {}) {
  if (!api || !auth) return;
  const activeSession = auth.sessionToken;
  try {
    const submissions = await api.listMine(activeSession);
    if (auth?.sessionToken !== activeSession) return;
    submissionState.clear();
    for (const submission of Array.isArray(submissions) ? submissions : []) {
      if (submission?.id) submissionState.set(submission.id, submission);
    }
    elements.connection.textContent = "云端连接正常";
  } catch (error) {
    if (isAuthError(error)) {
      saveAuth(null);
      elements.authMessage.textContent = "登录状态已失效，请重新登录";
      return;
    }
    elements.connection.textContent = "云端连接异常";
    if (!quiet) elements.message.textContent = `读取失败：${friendlyError(error)}`;
  }
  render();
  scheduleRefresh();
}

function scheduleRefresh() {
  clearTimeout(refreshTimer);
  if (!auth) return;
  const active = [...submissionState.values()].some(item => ["pending", "processing"].includes(item.status));
  if (active) refreshTimer = setTimeout(() => refreshSubmissions({ quiet: true }), 3000);
}

async function cancelSubmission(submission) {
  if (!auth || !confirm("只取消这一条任务吗？其他任务会继续执行。")) return;
  try {
    await api.cancelMine(submission.id, auth.sessionToken);
    await refreshSubmissions({ quiet: true });
  } catch (error) {
    elements.message.textContent = `取消失败：${friendlyError(error)}`;
  }
}

async function deleteSubmission(submission) {
  if (!auth) return;
  const active = ["pending", "processing"].includes(submission.status);
  const prompt = active
    ? "删除这一条任务吗？电脑端将在下一次状态检查时停止这项任务，其他任务不受影响。"
    : "永久删除这一条任务记录吗？其他任务不受影响。";
  if (!confirm(prompt)) return;

  try {
    const deleted = await api.removeMine(submission.id, auth.sessionToken);
    if (deleted !== true) throw new Error("任务不存在或已经删除");
    submissionState.delete(submission.id);
    elements.message.textContent = "已删除 1 条任务";
    render();
    scheduleRefresh();
  } catch (error) {
    elements.message.textContent = `删除失败：${friendlyError(error)}`;
  }
}

async function retrySubmission(submission) {
  if (!auth) return;
  try {
    await api.retryMine(submission.id, auth.sessionToken);
    await refreshSubmissions({ quiet: true });
  } catch (error) {
    elements.message.textContent = `重试失败：${friendlyError(error)}`;
  }
}

elements.showRegisterLink.addEventListener("click", event => {
  event.preventDefault();
  elements.authMessage.textContent = "";
  showAuthView("register", { updateHistory: true });
});

elements.showLoginLink.addEventListener("click", event => {
  event.preventDefault();
  elements.authMessage.textContent = "";
  showAuthView("login", { updateHistory: true });
});

window.addEventListener("hashchange", syncAuthViewFromLocation);
window.addEventListener("popstate", syncAuthViewFromLocation);

elements.loginForm.addEventListener("submit", async event => {
  event.preventDefault();
  elements.authMessage.textContent = "";
  elements.loginButton.disabled = true;
  try {
    const result = await api.login({
      username: elements.loginUsername.value,
      password: elements.loginPassword.value,
    });
    saveAuth({ sessionToken: result.session_token, username: result.username, isAdmin: result.is_admin === true });
    elements.loginPassword.value = "";
    elements.authMessage.textContent = "登录成功";
    render();
    await refreshSubmissions({ quiet: true });
    await refreshAdminConsole();
  } catch (error) {
    elements.authMessage.textContent = `登录失败：${friendlyError(error)}`;
  } finally {
    elements.loginButton.disabled = false;
  }
});

elements.registerForm.addEventListener("submit", async event => {
  event.preventDefault();
  elements.authMessage.textContent = "";
  elements.registerButton.disabled = true;
  try {
    const result = await api.register({
      username: elements.registerUsername.value,
      password: elements.registerPassword.value,
      invitationCode: elements.invitationCode.value,
    });
    saveAuth({ sessionToken: result.session_token, username: result.username });
    elements.registerPassword.value = "";
    elements.invitationCode.value = "";
    elements.authMessage.textContent = "注册成功，邀请码已使用";
    render();
    await refreshSubmissions({ quiet: true });
  } catch (error) {
    elements.authMessage.textContent = `注册失败：${friendlyError(error)}`;
  } finally {
    elements.registerButton.disabled = false;
  }
});

elements.logoutButton.addEventListener("click", async () => {
  const activeSession = auth?.sessionToken;
  if (!activeSession) return;
  elements.logoutButton.disabled = true;
  try {
    await api.logout(activeSession);
  } catch {
    // The local session is cleared even when the remote session already expired.
  } finally {
    saveAuth(null);
    showAuthView("login", { updateHistory: true });
    submissionState.clear();
    elements.authMessage.textContent = "已退出登录";
    elements.adminMessage.textContent = "";
    renderAdminCodes([]);
    renderAdminUsers([]);
    render();
    elements.logoutButton.disabled = false;
  }
});

elements.issueInvitationButton.addEventListener("click", async () => {
  if (!auth?.isAdmin) return;
  elements.issueInvitationButton.disabled = true;
  elements.adminMessage.textContent = "正在生成邀请码";
  try {
    await api.adminIssueInvitationCodes(auth.sessionToken, 10);
    await refreshAdminConsole({ successMessage: "已刷新 10 个当天可用邀请码，已使用记录已保留" });
  } catch (error) {
    elements.adminMessage.textContent = `生成失败：${friendlyError(error)}`;
  } finally {
    elements.issueInvitationButton.disabled = false;
  }
});

elements.rawText.addEventListener("input", () => {
  elements.lineCount.textContent = `已输入 ${countLines(elements.rawText.value)} 条`;
});

elements.form.addEventListener("submit", async event => {
  event.preventDefault();
  elements.message.textContent = "";
  if (!auth) {
    elements.authMessage.textContent = "请先登录或注册";
    return;
  }
  const rawText = elements.rawText.value;
  const lineCount = countLines(rawText);
  if (!lineCount) {
    elements.message.textContent = "请先输入账号任务";
    elements.rawText.focus();
    return;
  }

  const viewToken = randomToken();
  elements.submit.disabled = true;
  try {
    const created = await api.submitBatch({
      rawText,
      clientId: clientId(),
      viewToken,
      sessionToken: auth.sessionToken,
    });
    elements.rawText.value = "";
    elements.lineCount.textContent = "已输入 0 条";
    elements.message.textContent = `提交成功，云端已保存 ${created.line_count} 条`;
    await refreshSubmissions({ quiet: true });
  } catch (error) {
    if (isAuthError(error)) {
      saveAuth(null);
      elements.authMessage.textContent = "登录状态已失效，请重新登录";
    } else {
      elements.message.textContent = `提交失败：${friendlyError(error)}`;
    }
  } finally {
    elements.submit.disabled = !api || !auth;
  }
});

elements.refresh.addEventListener("click", () => {
  refreshSubmissions();
  refreshAdminConsole();
});

try {
  api = new SupabaseSubmissionApi(window.REMOTE_TASK_CONFIG || {});
  elements.connection.textContent = auth ? "正在读取提交记录" : "请登录后查看任务";
  updateAuthUI();
  render();
  refreshSubmissions({ quiet: true });
  refreshAdminConsole();
} catch (error) {
  elements.connection.textContent = "云端尚未配置";
  elements.message.textContent = friendlyError(error);
  elements.submit.disabled = true;
  updateAuthUI();
  render();
}
