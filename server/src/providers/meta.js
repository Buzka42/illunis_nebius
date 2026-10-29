// Meta Model API client (docs/RESEARCH.md (section 1)). OpenAI-compatible Chat Completions, plus the
// Responses API for the built-in `web_search` tool. Base https://api.meta.ai/v1 (Meta's developer blog).
// Secret META_API_KEY. Optional META_BASE_URL, accepted only as https on api.meta.ai under /v1.
// META_MODEL is required when META_API_KEY is set: no model id lives in code (D-E). Any *-contributor model is
// refused (they train on prompts) unless DATA_MODE=owner_any. The Nebius build runs with META_API_KEY unset (D-F).
// Fixed error codes only; nothing here logs or returns prompts, keys or upstream bodies.
// [unverified] Bearer auth (the blog passes the key as the OpenAI SDK api_key), the Responses citation
// shape (OpenAI `url_citation` annotations assumed) and 403 as the region refusal.
import { contributorRefused } from "../data-mode.js";
import { ProviderError, chatBody, pinnedBase, postJson, readCompletion } from "./chat.js";

export const META_PROVIDER = "meta";
export const META_HOST = "api.meta.ai";
export const META_BASE_URL = `https://${META_HOST}/v1`;
export const META_BASE_REFUSED = `META_BASE_URL refused: only https://${META_HOST} is allowed`;
export const META_CONTRIBUTOR_REFUSED = "META_MODEL refused: contributor models train on prompts";
export const META_MODEL_MISSING = "META_MODEL missing";

const blank = (v) => typeof v !== "string" || !v.trim();
export const metaBase = (env = {}) => pinnedBase(env.META_BASE_URL, META_HOST, META_BASE_URL);
export const metaModel = (env = {}) => (blank(env.META_MODEL) ? null : env.META_MODEL.trim());

export function metaConfigProblem(env = {}) {
  if (blank(env.META_API_KEY)) return "META_API_KEY missing";
  if (!metaModel(env)) return META_MODEL_MISSING;
  if (!metaBase(env)) return META_BASE_REFUSED;
  if (contributorRefused(env, metaModel(env))) return META_CONTRIBUTOR_REFUSED;
  return null;
}

function ready(env, model) {
  if (contributorRefused(env, model)) throw new ProviderError("meta_contributor_refused");
  if (metaConfigProblem(env)) throw new ProviderError("meta_not_configured", { fallback: true });
}

const headers = (env) => ({ Authorization: `Bearer ${env.META_API_KEY}` });

// Returns { content, tool_calls, model }.
export async function chatMeta(messages, env, { fetchFn = fetch, model = metaModel(env), tools, maxTokens, json, timeoutMs } = {}) {
  ready(env, model);
  const data = await postJson(`${metaBase(env)}/chat/completions`, {
    headers: headers(env),
    body: chatBody(model, messages, { tools, maxTokens, json }),
    fetchFn,
    timeoutMs,
    prefix: "meta",
  });
  return { ...readCompletion(data, "meta"), model };
}

// Responses API with the server-side web_search tool. Returns { text, results: [{title, url}] }.
export async function webSearchMeta(query, env, { fetchFn = fetch, model = metaModel(env), timeoutMs } = {}) {
  ready(env, model);
  const data = await postJson(`${metaBase(env)}/responses`, {
    headers: headers(env),
    body: {
      model,
      input: `Search the web for reputable public health guidance (WHO, NHS, CDC, peer-reviewed reviews) on: ${query}. ` +
        "Summarise the findings in three short neutral sentences.",
      tools: [{ type: "web_search" }],
      max_output_tokens: 600,
    },
    fetchFn,
    timeoutMs,
    prefix: "meta",
  });
  return readResponses(data);
}

// OpenAI Responses shape: output[] items of type "message" with content[] of type "output_text",
// each with annotations[] of type "url_citation" {url, title}. Only https URLs are kept.
export function readResponses(data) {
  const parts = (Array.isArray(data?.output) ? data.output : [])
    .filter((o) => o?.type === "message")
    .flatMap((o) => (Array.isArray(o.content) ? o.content : []))
    .filter((c) => c?.type === "output_text" && typeof c.text === "string");
  const text = parts.map((c) => c.text).join(" ").trim() || (typeof data?.output_text === "string" ? data.output_text.trim() : "");
  const seen = new Set();
  const results = [];
  for (const a of parts.flatMap((c) => (Array.isArray(c.annotations) ? c.annotations : []))) {
    if (a?.type !== "url_citation" || typeof a.url !== "string" || !/^https:\/\//i.test(a.url) || seen.has(a.url)) continue;
    seen.add(a.url);
    results.push({ title: typeof a.title === "string" && a.title ? a.title.slice(0, 200) : a.url, url: a.url });
  }
  if (!text) throw new ProviderError("meta_empty", { fallback: true });
  return { text, results: results.slice(0, 5) };
}
