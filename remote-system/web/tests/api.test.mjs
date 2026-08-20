import assert from "node:assert/strict";
import test from "node:test";
import { randomToken, SupabaseSubmissionApi } from "../api.js";

test("randomToken returns fixed-width hexadecimal data", () => {
  const cryptoObject = { getRandomValues(buffer) { buffer.fill(0xab); return buffer; } };
  assert.equal(randomToken(4, cryptoObject), "abababab");
});

test("web API converts an aborted request into a visible timeout error", async () => {
  const api = new SupabaseSubmissionApi({
    supabaseUrl: "https://project.supabase.co",
    supabaseAnonKey: "anon-key-value-that-is-public",
    requestTimeoutMs: 50,
    fetchImpl: (_url, options) => new Promise((_resolve, reject) => {
      options.signal.addEventListener("abort", () => {
        const error = new Error("aborted");
        error.name = "AbortError";
        reject(error);
      });
    }),
  });
  await assert.rejects(() => api.listMine("s".repeat(64)), /云端请求超时/);
});

test("web API uses only the anon key and expected RPC body", async () => {
  let request;
  const api = new SupabaseSubmissionApi({
    supabaseUrl: "https://project.supabase.co/",
    supabaseAnonKey: "anon-key-value-that-is-public",
    fetchImpl: async (url, options) => {
      request = { url, options };
      return { ok: true, status: 200, text: async () => JSON.stringify({ id: "task-1" }) };
    },
  });
  const result = await api.submit({
    rawText: "u校园 account password 100",
    clientId: "00000000-0000-0000-0000-000000000001",
    viewToken: "v".repeat(64),
    sessionToken: "s".repeat(64),
  });
  assert.equal(result.id, "task-1");
  assert.equal(request.url, "https://project.supabase.co/rest/v1/rpc/submit_submission");
  assert.equal(request.options.headers.apikey, "anon-key-value-that-is-public");
  assert.deepEqual(JSON.parse(request.options.body), {
    p_raw_text: "u校园 account password 100",
    p_client_id: "00000000-0000-0000-0000-000000000001",
    p_view_token: "v".repeat(64),
    p_session_token: "s".repeat(64),
  });
});

test("batch submission splits account lines through the batch RPC", async () => {
  let request;
  const api = new SupabaseSubmissionApi({
    supabaseUrl: "https://project.supabase.co",
    supabaseAnonKey: "anon-key-value-that-is-public",
    fetchImpl: async (url, options) => {
      request = { url, body: JSON.parse(options.body) };
      return { ok: true, status: 200, text: async () => JSON.stringify({ batch_id: "batch-1", line_count: 2 }) };
    },
  });
  const rawText = "u校园 first password\nwelearn second password";
  const result = await api.submitBatch({
    rawText,
    clientId: "00000000-0000-0000-0000-000000000001",
    viewToken: "v".repeat(64),
    sessionToken: "s".repeat(64),
  });

  assert.equal(result.line_count, 2);
  assert.equal(request.url, "https://project.supabase.co/rest/v1/rpc/submit_account_batch");
  assert.deepEqual(request.body, {
    p_raw_text: rawText,
    p_client_id: "00000000-0000-0000-0000-000000000001",
    p_view_token: "v".repeat(64),
    p_session_token: "s".repeat(64),
  });
});

test("auth operations use dedicated RPCs and send no browser secret", async () => {
  const requests = [];
  const api = new SupabaseSubmissionApi({
    supabaseUrl: "https://project.supabase.co",
    supabaseAnonKey: "anon-key-value-that-is-public",
    fetchImpl: async (url, options) => {
      requests.push({ url, body: JSON.parse(options.body) });
      return { ok: true, status: 200, text: async () => JSON.stringify({ session_token: "s".repeat(64) }) };
    },
  });
  await api.register({ username: "new-user", password: "password-123", invitationCode: "A".repeat(32) });
  await api.login({ username: "new-user", password: "password-123" });
  await api.logout("s".repeat(64));

  assert.deepEqual(requests.map(request => request.url.split("/").at(-1)), [
    "register_remote_user",
    "login_remote_user",
    "logout_remote_user",
  ]);
  assert.deepEqual(requests[0].body, {
    p_username: "new-user",
    p_password: "password-123",
    p_invitation_code: "A".repeat(32),
  });
  assert.deepEqual(requests[2].body, { p_session_token: "s".repeat(64) });
});

test("admin operations use the authenticated session token", async () => {
  const requests = [];
  const api = new SupabaseSubmissionApi({
    supabaseUrl: "https://project.supabase.co",
    supabaseAnonKey: "anon-key-value-that-is-public",
    fetchImpl: async (url, options) => {
      requests.push({ url, body: JSON.parse(options.body) });
      return { ok: true, status: 200, text: async () => JSON.stringify(["A".repeat(32)]) };
    },
  });
  await api.adminIssueInvitationCodes("s".repeat(64), 10);
  await api.adminListInvitationCodes("s".repeat(64));
  await api.adminListRemoteUsers("s".repeat(64));
  await api.adminResetRemoteUserPassword("s".repeat(64), "user-1");
  await api.adminDeleteRemoteUser("s".repeat(64), "user-2");

  assert.deepEqual(requests.map(request => request.url.split("/").at(-1)), [
    "admin_issue_invitation_codes",
    "admin_list_invitation_codes",
    "admin_list_remote_users",
    "admin_reset_remote_user_password",
    "admin_delete_remote_user",
  ]);
  assert.deepEqual(requests[0].body, { p_session_token: "s".repeat(64), p_count: 10 });
  assert.deepEqual(requests[1].body, { p_session_token: "s".repeat(64), p_issue_date: null });
  assert.deepEqual(requests[2].body, { p_session_token: "s".repeat(64) });
  assert.deepEqual(requests[3].body, { p_session_token: "s".repeat(64), p_target_user_id: "user-1" });
  assert.deepEqual(requests[4].body, { p_session_token: "s".repeat(64), p_target_user_id: "user-2" });
});

test("receipt operations use submission RPCs and send the session token", async () => {
  const requests = [];
  const api = new SupabaseSubmissionApi({
    supabaseUrl: "https://project.supabase.co",
    supabaseAnonKey: "anon-key-value-that-is-public",
    fetchImpl: async (url, options) => {
      requests.push({ url, body: JSON.parse(options.body) });
      return { ok: true, status: 200, text: async () => "true" };
    },
  });
  const token = "v".repeat(64);
  const sessionToken = "s".repeat(64);
  await api.get("submission-1", token, sessionToken);
  await api.cancel("submission-1", token, sessionToken);
  await api.retry("submission-1", token, sessionToken);
  await api.clear("submission-1", token, sessionToken);
  await api.remove("submission-1", token, sessionToken);

  assert.deepEqual(
    requests.map(request => request.url.split("/").at(-1)),
    ["get_submission", "cancel_submission", "retry_submission", "clear_submission", "delete_submission"],
  );
  for (const request of requests) {
    assert.deepEqual(request.body, {
      p_submission_id: "submission-1",
      p_view_token: token,
      p_session_token: sessionToken,
    });
    assert.equal("p_client_id" in request.body, false);
  }
});

test("account task operations require only the signed-in session and task id", async () => {
  const requests = [];
  const api = new SupabaseSubmissionApi({
    supabaseUrl: "https://project.supabase.co",
    supabaseAnonKey: "anon-key-value-that-is-public",
    fetchImpl: async (url, options) => {
      requests.push({ url, body: JSON.parse(options.body) });
      return { ok: true, status: 200, text: async () => "true" };
    },
  });
  const sessionToken = "s".repeat(64);
  await api.listMine(sessionToken);
  await api.cancelMine("submission-1", sessionToken);
  await api.retryMine("submission-1", sessionToken);
  await api.removeMine("submission-1", sessionToken);

  assert.deepEqual(requests.map(request => request.url.split("/").at(-1)), [
    "list_my_submissions",
    "cancel_my_submission",
    "retry_my_submission",
    "delete_my_submission",
  ]);
  assert.deepEqual(requests[0].body, { p_session_token: sessionToken, p_limit: 5000 });
  for (const request of requests.slice(1)) {
    assert.deepEqual(request.body, { p_submission_id: "submission-1", p_session_token: sessionToken });
    assert.equal("p_view_token" in request.body, false);
  }
});

test("wallet and recharge operations use authenticated RPCs", async () => {
  const requests = [];
  const api = new SupabaseSubmissionApi({
    supabaseUrl: "https://project.supabase.co",
    supabaseAnonKey: "anon-key-value-that-is-public",
    fetchImpl: async (url, options) => {
      requests.push({ url, body: JSON.parse(options.body) });
      return { ok: true, status: 200, text: async () => "{}" };
    },
  });
  const sessionToken = "s".repeat(64);
  await api.getMyProfile(sessionToken);
  await api.createRechargeRequest(sessionToken, 2000);
  await api.adminListRechargeRequests(sessionToken);
  await api.adminDecideRechargeRequest(sessionToken, "request-1", "approved", "已收款");
  await api.adminAdjustRemoteUserBalance(sessionToken, "user-1", 500, "测试加款");

  assert.deepEqual(requests.map(request => request.url.split("/").at(-1)), [
    "get_my_profile",
    "create_recharge_request",
    "admin_list_recharge_requests",
    "admin_decide_recharge_request",
    "admin_adjust_remote_user_balance",
  ]);
});
