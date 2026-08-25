export function isAuthError(error) {
  return /(^|[^a-z_])login_required([^a-z_]|$)/i.test(String(error?.message || ""));
}

export function isMissingAdminMetricsMigration(error) {
  const message = String(error?.message || "");
  return (error?.code === "PGRST202" || /schema cache/i.test(message))
    && /admin_get_queue_metrics/i.test(message);
}

export function settledResultsHaveAuthError(results) {
  return results.some(result => result?.status === "rejected" && isAuthError(result.reason));
}
