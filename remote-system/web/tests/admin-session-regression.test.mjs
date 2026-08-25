import assert from "node:assert/strict";
import test from "node:test";
import { SupabaseSubmissionApi } from "../api.js";
import { isAuthError, isMissingAdminMetricsMigration, settledResultsHaveAuthError } from "../auth-errors.js";

const missingMetricsError = Object.assign(new Error(
  "Could not find the function public.admin_get_queue_metrics(p_session_token) in the schema cache",
), { code: "PGRST202" });

test("a missing queue-metrics migration never expires an administrator session", async () => {
  const api = new SupabaseSubmissionApi({
    supabaseUrl: "https://project.supabase.co",
    supabaseAnonKey: "anon-key-value-that-is-public",
    fetchImpl: async () => ({
      ok: false,
      status: 404,
      text: async () => JSON.stringify({ code: "PGRST202", message: missingMetricsError.message }),
    }),
  });
  const results = await Promise.allSettled([
    Promise.resolve([]),
    Promise.resolve([]),
    Promise.resolve([]),
    api.adminGetQueueMetrics("s".repeat(64)),
  ]);
  const metricsError = results[3].reason;
  assert.equal(metricsError.code, "PGRST202");
  assert.equal(isMissingAdminMetricsMigration(metricsError), true);
  assert.equal(settledResultsHaveAuthError(results), false);
  assert.equal(isAuthError(metricsError), false);
});

test("login_required still expires an administrator session", () => {
  assert.equal(isAuthError(new Error("login_required")), true);
});
