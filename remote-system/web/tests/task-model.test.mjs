import assert from "node:assert/strict";
import test from "node:test";
import { batchStatus, groupSubmissions } from "../task-model.js";

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
