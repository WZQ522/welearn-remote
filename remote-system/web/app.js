import { randomToken, SupabaseSubmissionApi } from "./api.js";

const STORAGE_KEY = "unified-remote-submission-receipts-v2";
const CLIENT_KEY = "unified-remote-client-id-v1";

const elements = {
  form: document.querySelector("#submissionForm"),
  rawText: document.querySelector("#rawText"),
  lineCount: document.querySelector("#lineCount"),
  submit: document.querySelector("#submitButton"),
  message: document.querySelector("#formMessage"),
  connection: document.querySelector("#connectionText"),
  refresh: document.querySelector("#refreshButton"),
  clear: document.querySelector("#clearButton"),
  list: document.querySelector("#taskList"),
  count: document.querySelector("#taskCount"),
  empty: document.querySelector("#emptyState"),
  template: document.querySelector("#taskTemplate"),
};

let api = null;
let refreshTimer = null;
const submissionState = new Map();

function countLines(value) {
  return value.split(/\r?\n/).filter(line => line.trim()).length;
}

function loadReceipts() {
  try {
    const value = JSON.parse(localStorage.getItem(STORAGE_KEY) || "[]");
    return Array.isArray(value)
      ? value.filter(item => item?.id && item?.viewToken).slice(0, 50)
      : [];
  } catch {
    return [];
  }
}

function saveReceipts(receipts) {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(receipts.slice(0, 50)));
}

function clientId() {
  let value = localStorage.getItem(CLIENT_KEY);
  if (!value) {
    value = crypto.randomUUID();
    localStorage.setItem(CLIENT_KEY, value);
  }
  return value;
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
  if (!api) return;
  const receipts = loadReceipts();
  const results = await Promise.allSettled(receipts.map(async receipt => {
    const submission = await api.get(receipt.id, receipt.viewToken);
    if (submission) submissionState.set(receipt.id, submission);
  }));
  const failed = results.filter(result => result.status === "rejected").length;
  elements.connection.textContent = failed ? `云端连接异常 (${failed})` : "云端连接正常";
  if (!quiet && failed) elements.message.textContent = "部分记录暂时无法刷新";
  render();
  scheduleRefresh();
}

function scheduleRefresh() {
  clearTimeout(refreshTimer);
  const active = [...submissionState.values()].some(item => ["pending", "processing"].includes(item.status));
  if (active) refreshTimer = setTimeout(() => refreshSubmissions({ quiet: true }), 3000);
}

async function cancelSubmission(receipt) {
  try {
    await api.cancel(receipt.id, receipt.viewToken);
    await refreshSubmissions({ quiet: true });
  } catch (error) {
    elements.message.textContent = `取消失败：${error.message}`;
  }
}

async function retrySubmission(receipt) {
  try {
    await api.retry(receipt.id, receipt.viewToken);
    await refreshSubmissions({ quiet: true });
  } catch (error) {
    elements.message.textContent = `重试失败：${error.message}`;
  }
}

elements.rawText.addEventListener("input", () => {
  elements.lineCount.textContent = `已输入 ${countLines(elements.rawText.value)} 条`;
});

elements.form.addEventListener("submit", async event => {
  event.preventDefault();
  elements.message.textContent = "";
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
    const created = await api.submit({ rawText, clientId: clientId(), viewToken });
    const receipts = loadReceipts();
    receipts.unshift({
      id: created.id,
      viewToken,
      lineCount: created.line_count,
      createdAt: created.created_at,
    });
    saveReceipts(receipts);
    elements.rawText.value = "";
    elements.lineCount.textContent = "已输入 0 条";
    elements.message.textContent = `提交成功，云端已保存 ${created.line_count} 条`;
    await refreshSubmissions({ quiet: true });
  } catch (error) {
    elements.message.textContent = `提交失败：${error.message}`;
  } finally {
    elements.submit.disabled = false;
  }
});

elements.clear.addEventListener("click", async () => {
  const receipts = loadReceipts();
  if (!receipts.length || !confirm("清除当前设备上的全部提交记录？正在执行的任务不会停止。")) return;
  elements.clear.disabled = true;
  try {
    const results = await Promise.allSettled(receipts.map(receipt => api.clear(receipt.id, receipt.viewToken)));
    if (results.some(result => result.status === "rejected")) throw new Error("部分云端记录清除失败");
    localStorage.removeItem(STORAGE_KEY);
    submissionState.clear();
    elements.message.textContent = "提交记录已清除";
    render();
  } catch (error) {
    elements.message.textContent = `清除失败：${error.message}`;
  } finally {
    elements.clear.disabled = false;
  }
});

elements.refresh.addEventListener("click", () => refreshSubmissions());

try {
  api = new SupabaseSubmissionApi(window.REMOTE_TASK_CONFIG || {});
  elements.connection.textContent = "正在读取提交记录";
  render();
  refreshSubmissions({ quiet: true });
} catch (error) {
  elements.connection.textContent = "云端尚未配置";
  elements.message.textContent = error.message;
  elements.submit.disabled = true;
  render();
}
