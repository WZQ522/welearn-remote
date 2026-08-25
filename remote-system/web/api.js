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
  constructor({
    supabaseUrl,
    supabaseAnonKey,
    fetchImpl = (...args) => globalThis.fetch(...args),
    requestTimeoutMs = 30000,
  }) {
    this.origin = normalizeOrigin(supabaseUrl);
    if (!supabaseAnonKey || supabaseAnonKey.length < 20) throw new Error("Supabase 公共密钥尚未配置");
    if (typeof fetchImpl !== "function") throw new Error("浏览器请求功能不可用");
    if (!Number.isFinite(Number(requestTimeoutMs)) || Number(requestTimeoutMs) < 50) {
      throw new Error("请求超时时间无效");
    }
    this.anonKey = supabaseAnonKey;
    this.fetchImpl = fetchImpl;
    this.requestTimeoutMs = Number(requestTimeoutMs);
  }

  register({ username, password, invitationCode }) {
    return this.rpc("register_remote_user", {
      p_username: username,
      p_password: password,
      p_invitation_code: invitationCode,
    });
  }

  login({ username, password }) {
    return this.rpc("login_remote_user", {
      p_username: username,
      p_password: password,
    });
  }

  logout(sessionToken) {
    return this.rpc("logout_remote_user", { p_session_token: sessionToken });
  }

  adminIssueInvitationCodes(sessionToken, count = 10) {
    return this.rpc("admin_issue_invitation_codes", {
      p_session_token: sessionToken,
      p_count: count,
    });
  }

  adminListInvitationCodes(sessionToken, issueDate = null) {
    return this.rpc("admin_list_invitation_codes", {
      p_session_token: sessionToken,
      p_issue_date: issueDate,
    });
  }

  adminListRemoteUsers(sessionToken) {
    return this.rpc("admin_list_remote_users", {
      p_session_token: sessionToken,
    });
  }

  adminGetQueueMetrics(sessionToken) {
    return this.rpc("admin_get_queue_metrics", {
      p_session_token: sessionToken,
    });
  }

  adminResetRemoteUserPassword(sessionToken, userId) {
    return this.rpc("admin_reset_remote_user_password", {
      p_session_token: sessionToken,
      p_target_user_id: userId,
    });
  }

  adminDeleteRemoteUser(sessionToken, userId) {
    return this.rpc("admin_delete_remote_user", {
      p_session_token: sessionToken,
      p_target_user_id: userId,
    });
  }

  getMyProfile(sessionToken, limit = 100) {
    return this.rpc("get_my_profile", { p_session_token: sessionToken, p_limit: limit });
  }

  createRechargeRequest(sessionToken, amountCents, userNote = null) {
    return this.rpc("create_recharge_request", {
      p_session_token: sessionToken,
      p_amount_cents: amountCents,
      p_user_note: userNote,
    });
  }

  adminListRechargeRequests(sessionToken, limit = 200) {
    return this.rpc("admin_list_recharge_requests", { p_session_token: sessionToken, p_limit: limit });
  }

  adminDecideRechargeRequest(sessionToken, requestId, decision, adminNote = null) {
    return this.rpc("admin_decide_recharge_request", {
      p_session_token: sessionToken,
      p_request_id: requestId,
      p_decision: decision,
      p_admin_note: adminNote,
    });
  }

  adminAdjustRemoteUserBalance(sessionToken, targetUserId, amountCents, reason) {
    return this.rpc("admin_adjust_remote_user_balance", {
      p_session_token: sessionToken,
      p_target_user_id: targetUserId,
      p_amount_cents: amountCents,
      p_reason: reason,
    });
  }

  submit({ rawText, clientId, viewToken, sessionToken }) {
    return this.rpc("submit_submission", {
      p_raw_text: rawText,
      p_client_id: clientId,
      p_view_token: viewToken,
      p_session_token: sessionToken,
    });
  }

  submitBatch({ rawText, clientId, viewToken, sessionToken }) {
    return this.rpc("submit_account_batch", {
      p_raw_text: rawText,
      p_client_id: clientId,
      p_view_token: viewToken,
      p_session_token: sessionToken,
    });
  }

  get(submissionId, viewToken, sessionToken) {
    return this.rpc("get_submission", {
      p_submission_id: submissionId,
      p_view_token: viewToken,
      p_session_token: sessionToken,
    });
  }

  listMine(sessionToken, limit = 50) {
    return this.rpc("list_my_submissions", {
      p_session_token: sessionToken,
      p_limit: limit,
    });
  }

  cancelMine(submissionId, sessionToken) {
    return this.rpc("cancel_my_submission", {
      p_submission_id: submissionId,
      p_session_token: sessionToken,
    });
  }

  retryMine(submissionId, sessionToken) {
    return this.rpc("retry_my_submission", {
      p_submission_id: submissionId,
      p_session_token: sessionToken,
    });
  }

  removeMine(submissionId, sessionToken) {
    return this.rpc("delete_my_submission", {
      p_submission_id: submissionId,
      p_session_token: sessionToken,
    });
  }

  cancel(submissionId, viewToken, sessionToken) {
    return this.rpc("cancel_submission", {
      p_submission_id: submissionId,
      p_view_token: viewToken,
      p_session_token: sessionToken,
    });
  }

  retry(submissionId, viewToken, sessionToken) {
    return this.rpc("retry_submission", {
      p_submission_id: submissionId,
      p_view_token: viewToken,
      p_session_token: sessionToken,
    });
  }

  clear(submissionId, viewToken, sessionToken) {
    return this.rpc("clear_submission", {
      p_submission_id: submissionId,
      p_view_token: viewToken,
      p_session_token: sessionToken,
    });
  }

  remove(submissionId, viewToken, sessionToken) {
    return this.rpc("delete_submission", {
      p_submission_id: submissionId,
      p_view_token: viewToken,
      p_session_token: sessionToken,
    });
  }

  async rpc(name, body) {
    const controller = typeof AbortController === "function" ? new AbortController() : null;
    const timeout = setTimeout(() => controller?.abort(), this.requestTimeoutMs);
    try {
      const response = await this.fetchImpl(`${this.origin}/rest/v1/rpc/${name}`, {
        method: "POST",
        headers: {
          apikey: this.anonKey,
          authorization: `Bearer ${this.anonKey}`,
          "content-type": "application/json",
        },
        body: JSON.stringify(body),
        ...(controller ? { signal: controller.signal } : {}),
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
    } catch (error) {
      if (controller?.signal.aborted) throw new Error("云端请求超时，请检查网络后重试");
      throw error;
    } finally {
      clearTimeout(timeout);
    }
  }
}
