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

const distributionFields = [
  ["score100", "score_100"],
  ["score90To99", "score_90_99"],
  ["score80To89", "score_80_89"],
  ["score60To79", "score_60_79"],
  ["scoreBelow60", "score_below_60"],
];

function nonNegativeInteger(value) {
  const number = Number(value);
  return Number.isInteger(number) && number >= 0 ? number : 0;
}

function percent(value) {
  const number = Number(value);
  return Number.isFinite(number) && number >= 0 && number <= 100 ? number : null;
}

function emptyDistribution() {
  return {
    score100: 0,
    score90To99: 0,
    score80To89: 0,
    score60To79: 0,
    scoreBelow60: 0,
    total: 0,
  };
}

function readDistribution(value) {
  const distribution = emptyDistribution();
  if (!value || typeof value !== "object") return distribution;
  for (const [target, source] of distributionFields) {
    distribution[target] = nonNegativeInteger(value[source] ?? value[target]);
  }
  distribution.total = distributionFields.reduce((total, [target]) => total + distribution[target], 0);
  return distribution;
}

function addDistribution(target, source) {
  for (const [field] of distributionFields) target[field] += source[field];
  target.total = distributionFields.reduce((total, [field]) => total + target[field], 0);
}

function isFinished(submission) {
  if (["pending", "processing"].includes(submission?.status)) return false;
  if (["waiting", "running"].includes(submission?.execution_status)) return false;
  return Boolean(submission?.status || submission?.execution_status);
}

function submissionScoreSummary(submission) {
  const value = submission?.score_summary ?? submission?.result_payload?.score_summary;
  if (!value || typeof value !== "object") return null;
  const scoredAccountCount = nonNegativeInteger(value.scored_account_count);
  const unscoredAccountCount = nonNegativeInteger(value.unscored_account_count);
  const averageScore = percent(value.average_score);
  const highestScore = percent(value.highest_score);
  const lowestScore = percent(value.lowest_score);
  if (scoredAccountCount < 1 || averageScore === null || highestScore === null || lowestScore === null) {
    return null;
  }
  return {
    scoredAccountCount,
    unscoredAccountCount,
    averageScore,
    highestScore,
    lowestScore,
    accountDistribution: readDistribution(value.account_distribution),
    itemDistribution: readDistribution(value.item_distribution),
  };
}

export function batchScoreSummary(items) {
  const entries = Array.isArray(items) ? items : [];
  const finishedEntries = entries.filter(isFinished);
  const accountDistribution = emptyDistribution();
  const itemDistribution = emptyDistribution();
  let scoredAccountCount = 0;
  let unscoredAccountCount = 0;
  let weightedScoreTotal = 0;
  let highestScore = null;
  let lowestScore = null;

  for (const entry of finishedEntries) {
    const score = submissionScoreSummary(entry);
    if (!score) {
      unscoredAccountCount += 1;
      continue;
    }
    scoredAccountCount += score.scoredAccountCount;
    unscoredAccountCount += score.unscoredAccountCount;
    weightedScoreTotal += score.averageScore * score.scoredAccountCount;
    highestScore = highestScore === null ? score.highestScore : Math.max(highestScore, score.highestScore);
    lowestScore = lowestScore === null ? score.lowestScore : Math.min(lowestScore, score.lowestScore);
    addDistribution(accountDistribution, score.accountDistribution);
    addDistribution(itemDistribution, score.itemDistribution);
  }

  const complete = entries.length > 0 && finishedEntries.length === entries.length;
  return {
    statusText: entries.length
      ? `${complete ? "执行完成" : "执行中"} ${finishedEntries.length}/${entries.length}`
      : "等待任务",
    finishedCount: finishedEntries.length,
    totalCount: entries.length,
    scoredAccountCount,
    unscoredAccountCount,
    averageScore: scoredAccountCount ? weightedScoreTotal / scoredAccountCount : null,
    highestScore,
    lowestScore,
    accountDistribution,
    itemDistribution,
  };
}
