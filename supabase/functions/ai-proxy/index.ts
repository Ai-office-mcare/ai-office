// ============================================================
//  AI 오피스 — AI 중계 서버 (Supabase Edge Function)
//
//  역할: 브라우저 대신 이 서버가 Claude/GPT/Gemini 를 호출합니다.
//        API 키는 여기(서버)에만 있고 브라우저로 내려가지 않습니다.
//
//  보안: 로그인한 사용자만 호출할 수 있습니다.
//        ALLOWED_EMAILS 를 지정하면 그 사람들만 쓸 수 있습니다.
//
//  외부 라이브러리를 쓰지 않습니다 (배포 실패 위험 최소화).
// ============================================================

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "content-type": "application/json" },
  });

// Supabase 가 자동으로 넣어주는 환경변수. 버전에 따라 이름이 달라 여러 개를 시도합니다.
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const PUBLIC_KEY =
  Deno.env.get("SUPABASE_ANON_KEY") ??
  Deno.env.get("SUPABASE_PUBLISHABLE_KEY") ??
  Deno.env.get("SUPABASE_PUBLISHABLE_OR_ANON_KEY") ??
  "";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "POST 만 허용됩니다" }, 405);

  // ── 1. 로그인 확인 ────────────────────────────────────────
  const authHeader = req.headers.get("Authorization") ?? "";
  if (!authHeader.toLowerCase().startsWith("bearer ")) {
    return json({ error: "로그인이 필요합니다." }, 401);
  }

  let email = "";
  try {
    const who = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
      headers: { Authorization: authHeader, apikey: PUBLIC_KEY },
    });
    if (!who.ok) return json({ error: "로그인이 유효하지 않습니다. 다시 로그인해 주세요." }, 401);
    const u = await who.json();
    email = String(u?.email ?? "").toLowerCase();
    if (!u?.id) return json({ error: "로그인이 유효하지 않습니다." }, 401);
  } catch (e) {
    return json({ error: "로그인 확인 실패: " + (e instanceof Error ? e.message : String(e)) }, 500);
  }

  // ── 2. 허용된 사람인지 확인 (요금 폭탄 방지) ──────────────
  //    Secrets 에 ALLOWED_EMAILS 를 넣으면 그 목록만 통과합니다.
  //    예:  ALLOWED_EMAILS = me@example.com,teammate@example.com
  //    비워두면 로그인한 사람은 누구나 쓸 수 있습니다.
  const allowList = (Deno.env.get("ALLOWED_EMAILS") ?? "")
    .split(",").map((s) => s.trim().toLowerCase()).filter(Boolean);

  if (allowList.length > 0 && !allowList.includes(email)) {
    return json({ error: `이 앱을 사용할 권한이 없습니다 (${email}). 관리자에게 문의하세요.` }, 403);
  }

  // ── 3. 요청 내용 읽기 ─────────────────────────────────────
  let body: { provider?: string; model?: string; system?: string; user?: string; effort?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "요청 형식이 올바르지 않습니다." }, 400);
  }

  const provider = body.provider ?? "";
  const model    = body.model ?? "";
  const system   = body.system ?? "";
  const prompt   = body.user ?? "";
  const effort   = body.effort ?? "medium";

  if (!prompt.trim()) return json({ error: "보낼 내용이 비어 있습니다." }, 400);
  if (!model.trim())  return json({ error: "모델명이 비어 있습니다." }, 400);

  // ── 4. 제공사별 호출 ──────────────────────────────────────
  try {
    let upstream: Response;

    if (provider === "claude") {
      const key = Deno.env.get("ANTHROPIC_API_KEY");
      if (!key) return json({ error: "서버에 ANTHROPIC_API_KEY 가 설정되지 않았습니다." }, 500);

      const payload: Record<string, unknown> = {
        model,
        max_tokens: 16000,
        system,
        messages: [{ role: "user", content: prompt }],
        stream: true,
      };
      // effort 는 Haiku 계열이 지원하지 않습니다.
      if (!/haiku/i.test(model)) payload.output_config = { effort };

      upstream = await fetch("https://api.anthropic.com/v1/messages", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-api-key": key,
          "anthropic-version": "2023-06-01",
        },
        body: JSON.stringify(payload),
      });

    } else if (provider === "gpt") {
      const key = Deno.env.get("OPENAI_API_KEY");
      if (!key) return json({ error: "서버에 OPENAI_API_KEY 가 설정되지 않았습니다." }, 500);

      upstream = await fetch("https://api.openai.com/v1/chat/completions", {
        method: "POST",
        headers: { "content-type": "application/json", authorization: `Bearer ${key}` },
        body: JSON.stringify({
          model,
          messages: [{ role: "system", content: system }, { role: "user", content: prompt }],
          stream: true,
        }),
      });

    } else if (provider === "gemini") {
      const key = Deno.env.get("GEMINI_API_KEY");
      if (!key) return json({ error: "서버에 GEMINI_API_KEY 가 설정되지 않았습니다." }, 500);

      upstream = await fetch(
        `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:streamGenerateContent?alt=sse`,
        {
          method: "POST",
          headers: { "content-type": "application/json", "x-goog-api-key": key },
          body: JSON.stringify({
            systemInstruction: { parts: [{ text: system }] },
            contents: [{ role: "user", parts: [{ text: prompt }] }],
          }),
        },
      );

    } else {
      return json({ error: `알 수 없는 제공사: ${provider}` }, 400);
    }

    // ── 5. 오류면 내용을 그대로 전달 ────────────────────────
    if (!upstream.ok) {
      const detail = (await upstream.text()).slice(0, 800);
      return json({ error: `[${provider}] HTTP ${upstream.status}`, detail }, upstream.status);
    }

    // ── 6. 스트리밍 그대로 흘려보내기 ───────────────────────
    return new Response(upstream.body, {
      headers: {
        ...CORS,
        "content-type": "text/event-stream; charset=utf-8",
        "cache-control": "no-cache",
      },
    });

  } catch (e) {
    return json({ error: "중계 중 오류: " + (e instanceof Error ? e.message : String(e)) }, 500);
  }
});
