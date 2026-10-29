// The council brain (neutral naming, D-E): one model call for the relay, the experts and session summaries.
// callBrain: the Meta Model API first when it is configured (the Meta build), the council model on Nebius second
// (the Nebius build runs with META_API_KEY unset, D-F). Falls back when Meta is not configured, answers 5xx or
// 429, times out, fails on the network, or refuses the region. Records which provider answered.
// Testing (owner, 2026-10-25): COUNCIL_TEST_PROVIDER=openrouter_poc puts free NVIDIA Nemotron models on OpenRouter
// in place of Nebius. Meta still goes first once META_API_KEY is set.
// Model ids come from env only. The data guard runs before any call. Errors carry fixed codes only.
// Web search lives in council/web.js (contract C3), not here.
import { META_BASE_REFUSED, META_CONTRIBUTOR_REFUSED, META_MODEL_MISSING, META_PROVIDER, chatMeta, metaConfigProblem, metaModel } from "../providers/meta.js";
import { NEBIUS_BASE_REFUSED, NEBIUS_PROVIDER, chatNebiusCouncil, councilNebiusConfigProblem } from "../nebius.js";
import { dataModeProblem } from "../data-mode.js";
import { MODELS } from "../models.js";
import { OPENROUTER_PROVIDER, openRouterConfigProblem, openRouterHeaders, openRouterUrl } from "../openrouter.js";
import { ProviderError, chatBody, postJson, readCompletion } from "../providers/chat.js";

export const COUNCIL_TEST_DEFAULT_MODEL = MODELS.council_test.model;
// role: "relay" (default), "expert" or "summary". Each has its own row and env override in models.js.
const TEST_ROWS = Object.freeze({ relay: MODELS.council_test, expert: MODELS.council_test_expert, summary: MODELS.summary_test });
const testOn = (env) => env.COUNCIL_TEST_PROVIDER === OPENROUTER_PROVIDER;
const testRow = (role) => TEST_ROWS[role] ?? TEST_ROWS.relay;
// An env override keeps the row's reasoning setting but drops JSON mode: the override may not list it.
export function testModel(env, role) {
  const row = testRow(role);
  const override = env[row.env]?.trim();
  return override ? { model: override, reasoning: row.reasoning, json: false } : row;
}

function testProblem(env) {
  if (env.COUNCIL_TEST_PROVIDER && !testOn(env)) return `COUNCIL_TEST_PROVIDER unknown: use ${OPENROUTER_PROVIDER} or leave unset`;
  const problem = openRouterConfigProblem(env, "COUNCIL_TEST_PROVIDER");
  if (problem) return problem;
  for (const role of Object.keys(TEST_ROWS)) {
    const guard = dataModeProblem(env, { provider: OPENROUTER_PROVIDER, model: testModel(env, role).model, role: "council" });
    if (guard) return guard;
  }
  return null;
}

// A fast failure (no endpoint, per-minute or upstream rate limit, 5xx) on the row's model moves to its fallback once.
// The account's per-day free cap is shared by every model, so it is never retried.
const retryable = (err) => err.status === 404 || err.status >= 500 || (err.status === 429 && err.limit !== "per_day");

async function chatTest(messages, env, { fetchFn = fetch, tools, maxTokens, json, timeoutMs, role } = {}) {
  const { model, reasoning, json: jsonMode, fallback } = testModel(env, role);
  const started = Date.now();
  const once = async (id, jsonOk, ms) => {
    const data = await postJson(openRouterUrl(env), {
      headers: openRouterHeaders(env),
      body: chatBody(id, messages, { tools, maxTokens, json: json && jsonOk, reasoning }),
      fetchFn,
      timeoutMs: ms,
      prefix: "openrouter",
    });
    return { ...readCompletion(data, "openrouter"), model: id };
  };
  try {
    return await once(model, jsonMode, timeoutMs);
  } catch (err) {
    const left = (timeoutMs ?? 20_000) - (Date.now() - started);
    if (!fallback || !(err instanceof ProviderError) || !retryable(err) || left < 1000) throw err;
    return once(fallback, false, left);
  }
}

// Thrown before any outbound call; index.js maps it to 503 not_configured with this detail.
export function notConfigured(detail) {
  const err = new Error("not configured");
  err.detail = detail;
  return err;
}

// A Meta key with a missing model, a refused model or a refused base URL is a config error, never a reason to
// fall back silently.
const META_HARD = new Set([META_CONTRIBUTOR_REFUSED, META_BASE_REFUSED, META_MODEL_MISSING]);

// Returns a refusal reason or null when at least one council brain provider can be used.
export function brainConfigProblem(env = {}) {
  const meta = metaConfigProblem(env);
  if (META_HARD.has(meta)) return meta;
  if (testOn(env) || env.COUNCIL_TEST_PROVIDER) return testProblem(env);
  const metaGuard = meta ? null : dataModeProblem(env, { provider: META_PROVIDER, model: metaModel(env), role: "council" });
  if (metaGuard) return metaGuard;
  const nebius = councilNebiusConfigProblem(env);
  if (nebius === NEBIUS_BASE_REFUSED || /refused/.test(nebius ?? "")) return nebius; // base or contributor refused
  const nebiusGuard = nebius ? null : dataModeProblem(env, { provider: NEBIUS_PROVIDER, model: env.COUNCIL_NEBIUS_MODEL, role: "council" });
  if (nebiusGuard) return nebiusGuard;
  if (meta && nebius) return `no council provider: ${meta}; ${nebius}`;
  return null;
}

export const primaryReady = (env) => !metaConfigProblem(env);

// Returns { content, tool_calls, provider, model }. opts: fetchFn, tools, maxTokens, json, timeoutMs, role.
export async function callBrain(messages, env = {}, opts = {}) {
  const problem = brainConfigProblem(env);
  if (problem) throw notConfigured(problem);
  let first = null;
  if (primaryReady(env)) {
    try {
      return { ...(await chatMeta(messages, env, opts)), provider: META_PROVIDER };
    } catch (err) {
      if (!err?.fallback) throw err;
      first = err;
    }
  }
  if (testOn(env)) return { ...(await chatTest(messages, env, opts)), provider: OPENROUTER_PROVIDER };
  if (councilNebiusConfigProblem(env)) throw first ?? notConfigured("no council provider");
  return { ...(await chatNebiusCouncil(messages, env, opts)), provider: NEBIUS_PROVIDER };
}
