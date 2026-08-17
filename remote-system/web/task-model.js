export function groupSubmissions(submissions) {
  const groups = new Map();
  for (const submission of Array.isArray(submissions) ? submissions : []) {
    if (!submission?.id) continue;
    const batchId = submission.batch_id || submission.id;
    if (!groups.has(batchId)) {
      groups.set(batchId, { id: batchId, createdAt: submission.created_at || null, items: [] });
    }
    groups.get(batchId).items.push(submission);
  }

  for (const group of groups.values()) {
    group.items.sort((left, right) => {
      const position = Number(left.batch_position || 1) - Number(right.batch_position || 1);
      if (position) return position;
      return new Date(left.created_at || 0) - new Date(right.created_at || 0);
    });
  }

  return [...groups.values()].sort(
    (left, right) => new Date(right.createdAt || 0) - new Date(left.createdAt || 0),
  );
}

export function batchStatus(items) {
  const entries = Array.isArray(items) ? items : [];
  if (!entries.length) return { label: "空批次", tone: "pending" };
  if (entries.every(item => item.execution_status === "completed")) return { label: "全部完成", tone: "completed" };
  if (entries.some(item => item.status === "processing" || item.execution_status === "running")) return { label: "执行中", tone: "processing" };
  if (entries.some(item => item.status === "pending")) return { label: "等待电脑", tone: "pending" };
  if (entries.every(item => item.status === "canceled")) return { label: "已取消", tone: "failed" };
  if (entries.some(item => item.execution_status === "partial" || item.execution_status === "needs_action")) return { label: "部分完成", tone: "warning" };
  if (entries.some(item => item.status === "failed" || item.execution_status === "failed")) return { label: "存在失败", tone: "failed" };
  return { label: "已结束", tone: "warning" };
}
