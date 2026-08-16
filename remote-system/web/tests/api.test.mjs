import assert from "node:assert/strict";
import test from "node:test";
import { randomToken, SupabaseSubmissionApi } from "../api.js";

test("randomToken returns fixed-width hexadecimal data", () => {
  const cryptoObject = { getRandomValues(buffer) { buffer.fill(0xab); return buffer; } };
  assert.equal(randomToken(4, cryptoObject), "abababab");
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
  });
  assert.equal(result.id, "task-1");
  assert.equal(request.url, "https://project.supabase.co/rest/v1/rpc/submit_submission");
  assert.equal(request.options.headers.apikey, "anon-key-value-that-is-public");
  assert.deepEqual(JSON.parse(request.options.body), {
    p_raw_text: "u校园 account password 100",
    p_client_id: "00000000-0000-0000-0000-000000000001",
    p_view_token: "v".repeat(64),
  });
});

test("receipt operations use submission RPCs and never send the client id", async () => {
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
  await api.get("submission-1", token);
  await api.cancel("submission-1", token);
  await api.retry("submission-1", token);
  await api.clear("submission-1", token);

  assert.deepEqual(
    requests.map(request => request.url.split("/").at(-1)),
    ["get_submission", "cancel_submission", "retry_submission", "clear_submission"],
  );
  for (const request of requests) {
    assert.deepEqual(request.body, { p_submission_id: "submission-1", p_view_token: token });
    assert.equal("p_client_id" in request.body, false);
  }
});
