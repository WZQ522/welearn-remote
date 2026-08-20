import assert from "node:assert/strict";
import test from "node:test";
import { batchScoreSummary, batchStatus, groupSubmissions, submissionUnitSummary } from "../task-model.js";

test("submissions are grouped by batch and ordered by account position", () => {
  const groups = groupSubmissions([
    { id: "b-2", batch_id: "batch-1", batch_position: 2, created_at: "2026-08-17T00:00:00.000002Z" },
    { id: "legacy", created_at: "2026-08-16T00:00:00Z" },
    { id: "b-1", batch_id: "batch-1", batch_position: 1, created_at: "2026-08-17T00:00:00.000001Z" },
  ]);
  assert.deepEqual(groups.map(group => group.id), ["batch-1", "legacy"]);
  assert.deepEqual(groups[0].items.map(item => item.id), ["b-1", "b-2"]);
  assert.deepEqual(groups[1].items.map(item => item.id), ["legacy"]);
});

test("batch status reflects independent child states", () => {
  assert.deepEqual(batchStatus([{ execution_status: "completed" }, { execution_status: "completed" }]), {
    label: "全部完成",
    tone: "completed",
  });
  assert.equal(batchStatus([{ status: "completed" }, { status: "processing" }]).label, "执行中");
  assert.equal(batchStatus([{ status: "completed" }, { execution_status: "partial" }]).label, "部分完成");
});

test("batch score summary aggregates real account and item score distributions", () => {
  const summary = batchScoreSummary([
    {
      status: "completed",
      execution_status: "completed",
      result_payload: {
        score_summary: {
          scored_account_count: 1,
          unscored_account_count: 0,
          average_score: 96,
          highest_score: 96,
          lowest_score: 96,
          account_distribution: {
            score_100: 0,
            score_90_99: 1,
            score_80_89: 0,
            score_60_79: 0,
            score_below_60: 0,
          },
          item_distribution: {
            score_100: 2,
            score_90_99: 1,
            score_80_89: 0,
            score_60_79: 0,
            score_below_60: 0,
          },
        },
      },
    },
    {
      status: "completed",
      execution_status: "completed",
      result_payload: {
        score_summary: {
          scored_account_count: 1,
          unscored_account_count: 0,
          average_score: 78,
          highest_score: 78,
          lowest_score: 78,
          account_distribution: {
            score_100: 0,
            score_90_99: 0,
            score_80_89: 0,
            score_60_79: 1,
            score_below_60: 0,
          },
          item_distribution: {
            score_100: 0,
            score_90_99: 0,
            score_80_89: 1,
            score_60_79: 1,
            score_below_60: 1,
          },
        },
      },
    },
    { status: "failed", execution_status: "failed" },
  ]);

  assert.equal(summary.statusText, "执行完成 3/3");
  assert.equal(summary.scoredAccountCount, 2);
  assert.equal(summary.unscoredAccountCount, 1);
  assert.equal(summary.averageScore, 87);
  assert.equal(summary.highestScore, 96);
  assert.equal(summary.lowestScore, 78);
  assert.deepEqual(summary.accountDistribution, {
    score100: 0,
    score90To99: 1,
    score80To89: 0,
    score60To79: 1,
    scoreBelow60: 0,
    total: 2,
  });
  assert.deepEqual(summary.itemDistribution, {
    score100: 2,
    score90To99: 1,
    score80To89: 1,
    score60To79: 1,
    scoreBelow60: 1,
    total: 6,
  });
});

test("unfinished and legacy records never create synthetic scores", () => {
  const summary = batchScoreSummary([
    { status: "processing", execution_status: "running" },
    { status: "completed", execution_status: "completed" },
  ]);
  assert.equal(summary.statusText, "执行中 1/2");
  assert.equal(summary.scoredAccountCount, 0);
  assert.equal(summary.unscoredAccountCount, 1);
  assert.equal(summary.averageScore, null);
});

test("unit summary exposes recognized and selected billable units without inventing legacy values", () => {
  assert.deepEqual(submissionUnitSummary({
    unit_summary: {
      available_unit_count: 6,
      selected_unit_count: 1,
      unit_price_cents: 50,
      estimated_amount_cents: 50,
    },
  }), {
    availableUnitCount: 6,
    selectedUnitCount: 1,
    unitPriceCents: 50,
    estimatedAmountCents: 50,
  });
  assert.equal(submissionUnitSummary({}), null);
  assert.equal(submissionUnitSummary({ unit_summary: { available_unit_count: 0 } }), null);
});
