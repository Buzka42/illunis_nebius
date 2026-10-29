// Reply generation through one OpenAI-compatible endpoint, chosen by REPLY_PROVIDER:
//   nebius        -> Nebius Token Factory, the TARGET provider (owner decision 2026-10-24);
//   opencode_poc  -> OpenCode Go, testing only;
//   openrouter_poc -> OpenRouter free models, testing only (synthetic data; openrouter.js);
//   unset         -> self-hosted REPLY_LLM_BASE_URL, third-party hosts refused.
// Missing or refused config -> 503 reply_not_configured, before any outbound call.
// Crisis -> fixed referral, before any outbound call. Model output passes the safety gate with at most one
// repair call (contract C4): passed, repaired, or replaced (crisis referral or SAFE_FALLBACK_TEXT).
// council_suggested (contract C5) is true only for a passed or repaired answer to a big question.
// Results carry fixed codes only; nothing here logs or returns the transcript or prompt.
// The client is never trusted for prompt text: the system prompt is rebuilt from
// plan.personality_id and plan.skill_id. Memories come from the phone's top-level context (phone-context.js,
// data only) and the server's store; plan.memories is still ignored.
// The model decides when the medical line applies: it starts a reply whose wrong use could cause harm with
// HEALTH_MARKER (prompt in turn.js). The marker is stripped before the gate and never reaches the client; a marked
// reply gets health: true and NOT_MEDICAL_ADVICE once, added after the gate. No keyword matching on this path.
// /reply/stream (reply-stream.js) reuses prepareReply, replyEndpoint and requestBody: one set of rules.
import { REFERRAL_TEXT, gateWithRepair, isCrisis, repairInstruction, stripHealthMarker, withHealthLine } from "./safety.js";
import { councilSuggested } from "./council-trigger.js";
import { RECALL_LIMIT, buildSystemPrompt, recallMemories } from "./turn.js";
import { getPersonality, getSkill } from "./content.js";
import { OPENCODE_URL, SESSION_HEADER } from "./opencode.js";
import { NEBIUS_PROVIDER, nebiusConfigProblem, nebiusEndpoint } from "./nebius.js";
import { MODELS } from "./models.js";
import { OPENROUTER_PROVIDER, openRouterConfigProblem, openRouterHeaders, openRouterUrl } from "./openrouter.js";
import { dataModeProblem } from "./data-mode.js";
import { shortTermBlock } from "./phone-context.js";

export const REPLY_TIMEOUT_MS = 20_000;
export const REPAIR_TIMEOUT_MS = 10_000; // the one repair call after a gate failure
export const REPLY_TEMPERATURE = 0.4;
export const REPLY_MAX_TOKENS = 1024; // reasoning models need headroom
const MAX_TRANSCRIPT = 4000;
const MAX_MEMORY_TEXT = 500;

// Exact hosts and their subdomains. Meta and Google hosts are refused as whole domains.
export const BLOCKED_HOSTS = [
  "api.openai.com", "openai.com", "api.anthropic.com", "anthropic.com", "opencode.ai", "openrouter.ai",
  // Meta
  "meta.ai", "meta.com", "llama.com", "facebook.com", "fb.com", "instagram.com", "whatsapp.com",
  // Google
  "google.com", "googleapis.com", "googleusercontent.com", "gemini.google.com", "withgoogle.com",
  "goog", "google", "gstatic.com", "run.app", "cloudfunctions.net",
];

// Proof-of-concept and testing ONLY (owner decision 2026-10-24): REPLY_PROVIDER=opencode_poc sends
// /reply health text to OpenCode Go free models. Opt-in per deployment; never the default.
// The release build uses REPLY_PROVIDER=nebius (see nebius.js); this switch is removed before submission.
export const POC_PROVIDER = "opencode_poc";
export const POC_DEFAULT_MODEL = MODELS.reply.model;
export const OPENROUTER_DEFAULT_MODEL = MODELS.reply_openrouter.model;

// Returns a refusal reason (names the variable, never its value) or null when usable.
// The data guard comes first: under DATA_MODE=owner_real the free test providers and contributor models refuse.
export function replyConfigProblem(env = {}) {
  const guard = dataModeProblem(env, { provider: env.REPLY_PROVIDER, model: env.REPLY_LLM_MODEL, role: "reply" });
  if (guard) return guard;
  if (env.REPLY_PROVIDER === POC_PROVIDER) {
    return env.OPENCODE_API_KEY ? null : "OPENCODE_API_KEY missing for REPLY_PROVIDER=opencode_poc";
  }
  if (env.REPLY_PROVIDER === OPENROUTER_PROVIDER) return openRouterConfigProblem(env, "REPLY_PROVIDER");
  if (env.REPLY_PROVIDER === NEBIUS_PROVIDER) return nebiusConfigProblem(env);
  if (env.REPLY_PROVIDER) {
    return `REPLY_PROVIDER unknown: use ${NEBIUS_PROVIDER}, ${POC_PROVIDER}, ${OPENROUTER_PROVIDER} or leave unset`;
  }
  const value = env.REPLY_LLM_BASE_URL;
  if (!value) return "REPLY_LLM_BASE_URL missing: set it to a self-hosted OpenAI-compatible endpoint";
  let url;
  try {
    url = new URL(value);
  } catch {
    return "REPLY_LLM_BASE_URL is not a valid URL";
  }
  if (url.protocol !== "https:" && url.protocol !== "http:") return "REPLY_LLM_BASE_URL must be http or https";
  const host = url.hostname.toLowerCase().replace(/\.$/, "");
  if (BLOCKED_HOSTS.some((h) => host === h || host.endsWith(`.${h}`))) {
    return "REPLY_LLM_BASE_URL points at a third-party API; it must be self-hosted";
  }
  if (!env.REPLY_LLM_MODEL) return "REPLY_LLM_MODEL missing";
  return null;
}

export function chatUrl(base) {
  const b = base.replace(/\/+$/, "");
  return b.endsWith("/chat/completions") ? b : `${b}/chat/completions`;
}

const LABEL_TEXT = {
  fact: "fact",
  note: "note",
  observation: "observation (tentative, not a fact or conclusion)",
};

export function memoryBlock(memories = []) {
  const lines = memories
    .filter((m) => m && typeof m.text === "string" && m.text.trim())
    .slice(0, RECALL_LIMIT)
    .map((m) => {
      // Anything not explicitly a fact or note is treated as a tentative observation.
      const label = m.label === "fact" || m.label === "note" ? LABEL_TEXT[m.label] : LABEL_TEXT.observation;
      const conf = typeof m.confidence === "number" ? `, confidence ${m.confidence}` : "";
      return `- [${label}${conf}] ${m.text.slice(0, MAX_MEMORY_TEXT)}`;
    });
  return lines.length ? `Memories:\n${lines.join("\n")}` : "";
}

// Takes server-built values only: { system_prompt, memories } from content and the store.
export function buildReplyMessages({ system_prompt, memories, shortTerm }, transcript) {
  const system = [system_prompt, shortTermBlock(shortTerm), memoryBlock(memories)].filter(Boolean).join("\n\n");
  return [
    { role: "system", content: system },
    { role: "user", content: transcript },
  ];
}

// Reasoning models may emit <think> blocks in content; never pass those on.
export const stripThinking = (s) => s.replace(/<think>[\s\S]*?<\/think>/gi, "").trim();

function validate(plan, transcript) {
  if (!plan || typeof plan !== "object" || Array.isArray(plan)) return "plan required";
  if (typeof transcript !== "string" || !transcript.trim()) return "transcript required";
  if (transcript.length > MAX_TRANSCRIPT) return "transcript too long";
  return null;
}

// Resolves content from ids. Returns { personality, skill } or { error }.
function resolveContent(plan) {
  const personality = typeof plan.personality_id === "string" ? getPersonality(plan.personality_id) : null;
  if (!personality) return { error: "unknown personality_id" };
  if (plan.skill_id == null) return { personality, skill: null };
  const skill = typeof plan.skill_id === "string" ? getSkill(plan.skill_id) : null;
  return skill ? { personality, skill } : { error: "unknown skill_id" };
}

// Client fields that are dropped, as fixed log codes. Never their content.
const ignoredFields = (plan) => [
  ...("system_prompt" in plan ? ["client_system_prompt_ignored"] : []),
  ...("memories" in plan ? ["client_memories_ignored"] : []),
];

const result = (status, body, code = null) => ({ status, body, code });
export const referral = (personality_id, code, health = false) =>
  result(200, { text: health ? withHealthLine(REFERRAL_TEXT) : REFERRAL_TEXT, personality_id, safety: "replaced", health, council_suggested: false }, code);

// Fixed log code per gate outcome.
export const gateCode = ({ safety, crisis }) => (crisis ? "reply_crisis" : safety === "repaired" ? "reply_repaired" : safety === "replaced" ? "reply_replaced" : null);

// The repair turn for a reply that failed the gate: the assistant text so far, then the fixed instruction.
export const repairMessages = (messages, assistantText, ruleId, extra = "") => [
  ...messages,
  { role: "assistant", content: assistantText },
  { role: "user", content: extra ? `${repairInstruction(ruleId)} ${extra}` : repairInstruction(ruleId) },
];

export class TimeoutError extends Error {}

// { url, model, headers } for the configured provider. Call only after replyConfigProblem(env) is null.
export function replyEndpoint(env) {
  if (env.REPLY_PROVIDER === NEBIUS_PROVIDER) return nebiusEndpoint(env);
  if (env.REPLY_PROVIDER === OPENROUTER_PROVIDER) {
    return { url: openRouterUrl(env), model: env.REPLY_LLM_MODEL || OPENROUTER_DEFAULT_MODEL, headers: openRouterHeaders(env) };
  }
  if (env.REPLY_PROVIDER === POC_PROVIDER) {
    return {
      url: env.OPENCODE_BASE_URL || OPENCODE_URL,
      model: env.REPLY_LLM_MODEL || POC_DEFAULT_MODEL,
      headers: { Authorization: `Bearer ${env.OPENCODE_API_KEY}`, [SESSION_HEADER]: `illunis-reply-poc-${crypto.randomUUID()}` },
    };
  }
  return {
    url: chatUrl(env.REPLY_LLM_BASE_URL),
    model: env.REPLY_LLM_MODEL,
    headers: env.REPLY_LLM_KEY ? { Authorization: `Bearer ${env.REPLY_LLM_KEY}` } : {},
  };
}

// One request body for both paths; the streaming path only adds stream: true.
// On Nebius the reply model runs with reasoning effort none: otherwise it writes its planning into the
// answer text (live run 2026-10-29; the gate then replaced those replies).
export const requestBody = (model, messages, stream = false, env = {}) =>
  JSON.stringify({
    model,
    messages,
    temperature: REPLY_TEMPERATURE,
    max_tokens: REPLY_MAX_TOKENS,
    ...(stream ? { stream: true } : {}),
    ...(env.REPLY_PROVIDER === NEBIUS_PROVIDER ? { reasoning: { effort: "none" } } : {}),
  });

export async function callModel(messages, env, fetchFn, timeoutMs) {
  const controller = new AbortController();
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => {
      controller.abort();
      reject(new TimeoutError());
    }, timeoutMs);
  });
  const { url, model, headers } = replyEndpoint(env);
  const request = (async () => {
    const res = await fetchFn(url, {
      method: "POST",
      headers: { "Content-Type": "application/json", ...headers },
      signal: controller.signal,
      body: requestBody(model, messages, false, env),
    });
    if (!res.ok) throw new Error("upstream status");
    const data = await res.json();
    const content = data?.choices?.[0]?.message?.content;
    const text = typeof content === "string" ? stripThinking(content) : "";
    if (!text) throw new Error("upstream empty");
    return text;
  })();
  try {
    return await Promise.race([request, timeout]);
  } finally {
    clearTimeout(timer);
    request.catch(() => {}); // a late rejection after timeout must not surface
  }
}

// Returns { status, body, code, ignored }. `code` is a fixed string for logs, null on
// success; `ignored` lists fixed codes for dropped client fields.
export async function runReply({ plan, transcript, phone, env = {}, memoryStore, now = Date.now(), fetchFn = fetch, timeoutMs = REPLY_TIMEOUT_MS }) {
  const prep = await prepareReply({ plan, transcript, phone, env, memoryStore, now });
  if (prep.early) return prep.early;
  const { personality, messages, ignored } = prep;
  let text;
  try {
    text = await callModel(messages, env, fetchFn, timeoutMs);
  } catch (err) {
    if (isTimeout(err)) return { ...result(504, { error: "reply_timeout" }, "reply_timeout"), ignored };
    return { ...result(502, { error: "reply_upstream" }, "reply_upstream"), ignored };
  }
  // The marker is stripped before the gate; health is true when the answer or its repair carried it.
  const first = stripHealthMarker(text);
  if (!first.text) return { ...result(502, { error: "reply_upstream" }, "reply_upstream"), ignored };
  let health = first.health;
  const gated = await gateWithRepair(first.text, async (ruleId) => {
    const repaired = stripHealthMarker(
      await callModel(repairMessages(messages, first.text, ruleId), env, fetchFn, Math.min(timeoutMs, REPAIR_TIMEOUT_MS)));
    health ||= repaired.health;
    return repaired.text;
  });
  // The health line is added after the gate, so the gate can never remove it.
  const body = {
    text: health ? withHealthLine(gated.text) : gated.text,
    personality_id: personality.id,
    safety: gated.safety,
    health,
    council_suggested: councilSuggested(transcript, gated.safety),
  };
  return { ...result(200, body, gateCode(gated)), ignored };
}

export const isTimeout = (err) => err instanceof TimeoutError || err?.name === "AbortError" || err?.name === "TimeoutError";

// Everything before the model call, shared by /reply and /reply/stream: validation, crisis,
// content ids, provider config, server-side prompt and memories.
// Returns { early: { status, body, code, ignored } } when no model call may happen,
// otherwise { personality, messages, ignored }.
export async function prepareReply({ plan, transcript, phone, env = {}, memoryStore, now = Date.now() }) {
  const invalid = validate(plan, transcript);
  if (invalid) return { early: { ...result(400, { error: "bad_request", detail: invalid }, "bad_request"), ignored: [] } };
  const ignored = ignoredFields(plan);
  const early = (out) => ({ early: { ...out, ignored } });

  // Crisis never reaches the model, whether flagged by /turn or present in the transcript.
  // The crisis referral is fixed text (PLAN.md), so no disclaimer is appended to it.
  if (plan.crisis === true || isCrisis(transcript)) return early(referral(null, "reply_crisis"));

  const content = resolveContent(plan);
  if (content.error) return early(result(400, { error: "bad_request", detail: content.error }, "bad_request"));

  const problem = replyConfigProblem(env);
  if (problem) return early(result(503, { error: "reply_not_configured", detail: problem }, "reply_not_configured"));

  const { personality, skill } = content;
  // Phone memories first (memory lives on the phone), then the server store, capped together.
  const stored = memoryStore ? await recallMemories({ memoryStore, query: transcript, now }) : [];
  const memories = [...(phone?.memories ?? []), ...stored].slice(0, RECALL_LIMIT);
  const messages = buildReplyMessages({ system_prompt: buildSystemPrompt(personality, skill), memories, shortTerm: phone }, transcript);
  return { personality, messages, ignored };
}
