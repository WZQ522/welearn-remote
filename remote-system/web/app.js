import { randomToken, SupabaseSubmissionApi } from "./api.js?v=admin-console-v1";

const STORAGE_KEY = "unified-remote-submission-receipts-v2";
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
  clear: document.querySelector("#clearButton"),
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

function loadStoredReceipts() {
  try {
    const value = JSON.parse(localStorage.getItem(STORAGE_KEY) || "[]");
    return Array.isArray(value)
      ? value.filter(item => item?.id && item?.viewToken).slice(0, 50)
      : [];
  } catch {
    return [];
  }
}

function loadReceipts() {
  if (!auth) return [];
  return loadStoredReceipts().filter(item => item.username === auth.username);
}

function saveReceipt(receipt) {
  const receipts = loadStoredReceipts();
  receipts.unshift(receipt);
  localStorage.setItem(STORAGE_KEY, JSON.stringify(receipts.slice(0, 50)));
}

function clearCurrentReceipts() {
  const receipts = loadStoredReceipts().filter(item => item.username !== auth?.username);
  if (receipts.length) localStorage.setItem(STORAGE_KEY, JSON.stringify(receipts));
  else localStorage.removeItem(STORAGE_KEY);
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
    row.append(identity, activity);
    elements.adminUserList.append(row);
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

function render() {
  const receipts = loadReceipts();
  elements.list.replaceChildren();
  elements.count.textContent = `${receipts.length} 批`;
  elements.empty.hidden = receipts.length > 0;
  elements.clear.hidden = receipts.length === 0;

  for (const receipt of receipts) {
    const submission = submissionState.get(receipt.id) || {
      id: receipt.id,
      status: "pending",
      execution_status: "waiting",
      line_count: receipt.lineCount,
      task_total: receipt.lineCount,
      task_completed: 0,
      task_failed: 0,
      created_at: receipt.createdAt,
      attempt_count: 0,
    };
    const status = statusInfo(submission);
    const progress = progressInfo(submission);
    const card = elements.template.content.firstElementChild.cloneNode(true);
    card.dataset.status = status.tone;
    card.querySelector(".task-title").textContent = `批量任务 · ${submission.line_count || receipt.lineCount || 0} 条账号`;
    card.querySelector(".task-time").textContent = formatTime(submission.created_at);
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
    cancel.addEventListener("click", () => cancelSubmission(receipt));

    const retry = card.querySelector(".retry-button");
    retry.hidden = !(
      ["failed", "canceled"].includes(submission.status)
      || ["needs_action", "partial", "failed"].includes(submission.execution_status)
    );
    retry.addEventListener("click", () => retrySubmission(receipt));
    elements.list.append(card);
  }
  window.lucide?.createIcons();
}

async function refreshSubmissions({ quiet = false } = {}) {
  if (!api || !auth) return;
  const activeSession = auth.sessionToken;
  const receipts = loadReceipts();
  const results = await Promise.allSettled(receipts.map(async receipt => {
    const submission = await api.get(receipt.id, receipt.viewToken, activeSession);
    if (submission) submissionState.set(receipt.id, submission);
  }));
  const failed = results.filter(result => result.status === "rejected").length;
  if (failed && results.some(result => result.status === "rejected" && isAuthError(result.reason))) {
    saveAuth(null);
    elements.authMessage.textContent = "登录状态已失效，请重新登录";
    return;
  }
  elements.connection.textContent = failed ? `云端连接异常 (${failed})` : "云端连接正常";
  if (!quiet && failed) elements.message.textContent = "部分记录暂时无法刷新";
  render();
  scheduleRefresh();
}

function scheduleRefresh() {
  clearTimeout(refreshTimer);
  if (!auth) return;
  const active = [...submissionState.values()].some(item => ["pending", "processing"].includes(item.status));
  if (active) refreshTimer = setTimeout(() => refreshSubmissions({ quiet: true }), 3000);
}

async function cancelSubmission(receipt) {
  if (!auth) return;
  try {
    await api.cancel(receipt.id, receipt.viewToken, auth.sessionToken);
    await refreshSubmissions({ quiet: true });
  } catch (error) {
    elements.message.textContent = `取消失败：${friendlyError(error)}`;
  }
}

async function retrySubmission(receipt) {
  if (!auth) return;
  try {
    await api.retry(receipt.id, receipt.viewToken, auth.sessionToken);
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
    const created = await api.submit({
      rawText,
      clientId: clientId(),
      viewToken,
      sessionToken: auth.sessionToken,
    });
    saveReceipt({
      id: created.id,
      viewToken,
      lineCount: created.line_count,
      createdAt: created.created_at,
      username: auth.username,
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

elements.clear.addEventListener("click", async () => {
  const receipts = loadReceipts();
  if (!auth || !receipts.length || !confirm("清除当前账号在此设备上的全部提交记录？正在执行的任务不会停止。")) return;
  elements.clear.disabled = true;
  try {
    const results = await Promise.allSettled(receipts.map(receipt => api.clear(receipt.id, receipt.viewToken, auth.sessionToken)));
    if (results.some(result => result.status === "rejected")) throw new Error("部分云端记录清除失败");
    clearCurrentReceipts();
    submissionState.clear();
    elements.message.textContent = "提交记录已清除";
    render();
  } catch (error) {
    elements.message.textContent = `清除失败：${friendlyError(error)}`;
  } finally {
    elements.clear.disabled = false;
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
