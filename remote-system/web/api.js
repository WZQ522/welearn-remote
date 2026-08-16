function normalizeOrigin(value) {
  if (typeof value !== "string" || !value.trim()) throw new Error("Supabase 地址尚未配置");
  let url;
  try {
    url = new URL(value);
  } catch {
    throw new Error("Supabase 地址格式不正确");
  }
  if (url.protocol !== "https:") throw new Error("Supabase 地址必须使用 HTTPS");
  return url.origin;
}

export function randomToken(bytes = 32, cryptoObject = globalThis.crypto) {
  if (!cryptoObject?.getRandomValues) throw new Error("Secure random generator unavailable");
  const buffer = new Uint8Array(bytes);
  cryptoObject.getRandomValues(buffer);
  return Array.from(buffer, byte => byte.toString(16).padStart(2, "0")).join("");
}

export class SupabaseSubmissionApi {
  constructor({ supabaseUrl, supabaseAnonKey, fetchImpl = globalThis.fetch }) {
    this.origin = normalizeOrigin(supabaseUrl);
    if (!supabaseAnonKey || supabaseAnonKey.length < 20) throw new Error("Supabase 公共密钥尚未配置");
    if (typeof fetchImpl !== "function") throw new Error("浏览器请求功能不可用");
    this.anonKey = supabaseAnonKey;
    this.fetchImpl = fetchImpl;
  }

  submit({ rawText, clientId, viewToken }) {
    return this.rpc("submit_submission", {
      p_raw_text: rawText,
      p_client_id: clientId,
      p_view_token: viewToken,
    });
  }

  get(submissionId, viewToken) {
    return this.rpc("get_submission", { p_submission_id: submissionId, p_view_token: viewToken });
  }

  cancel(submissionId, viewToken) {
    return this.rpc("cancel_submission", { p_submission_id: submissionId, p_view_token: viewToken });
  }

  retry(submissionId, viewToken) {
    return this.rpc("retry_submission", { p_submission_id: submissionId, p_view_token: viewToken });
  }

  clear(submissionId, viewToken) {
    return this.rpc("clear_submission", { p_submission_id: submissionId, p_view_token: viewToken });
  }

  async rpc(name, body) {
    const response = await this.fetchImpl(`${this.origin}/rest/v1/rpc/${name}`, {
      method: "POST",
      headers: {
        apikey: this.anonKey,
        authorization: `Bearer ${this.anonKey}`,
        "content-type": "application/json",
      },
      body: JSON.stringify(body),
    });
    const text = await response.text();
    let data = null;
    if (text) {
      try { data = JSON.parse(text); } catch { data = { message: text }; }
    }
    if (!response.ok) {
      const message = data?.message || data?.error || `HTTP ${response.status}`;
      throw new Error(message);
    }
    return data;
  }
}
