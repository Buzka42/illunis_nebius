// POST /session/summary: stateless. The phone sends one finished session and keeps the summary in its
// short-term memory (last N sessions). Nothing is stored here. The council brain (council/provider.js: Meta when configured, then Nebius;
// the summary_test row on OpenRouter while testing) writes it, so the DATA_MODE guard applies. Crisis sessions get a fixed summary with no model call.
import { gateText, isCrisis } from "./safety.js";
import { callBrain } from "./council/provider.js";

export const MAX_TURNS = 80;
export const MAX_TURN_TEXT = 4000;
export const MAX_TOTAL = 24_000;
export const MAX_SUMMARY = 600;
export const SUMMARY_TIMEOUT_MS = 15_000;
export const CRISIS_SUMMARY = "The user raised a safety concern in this session and was given the crisis referral.";

const SYSTEM =
  "Summarise this conversation for the assistant's short-term memory in at most three short sentences " +
  "(under 400 characters). Keep what the user said about themselves, their plans and open questions. " +
  "Mark guesses as tentative. No diagnosis, no advice, no directive words. " +
  'Reply with JSON only: {"summary":string,"topics":[up to 5 short strings]}.';

// Returns an error string or null.
export function validateSession(turns) {
  if (!Array.isArray(turns) || !turns.length || turns.length > MAX_TURNS) return `turns must be an array of 1 to ${MAX_TURNS}`;
  let total = 0;
  for (const t of turns) {
    if (!t || (t.role !== "user" && t.role !== "assistant")) return "turn role must be user or assistant";
    if (typeof t.text !== "string" || t.text.length > MAX_TURN_TEXT) return `turn text must be a string of at most ${MAX_TURN_TEXT}`;
    total += t.text.length;
  }
  return total > MAX_TOTAL ? `session text over ${MAX_TOTAL} characters` : null;
}

const parse = (content) => {
  try {
    return JSON.parse(String(content).match(/\{[\s\S]*\}/)?.[0] ?? "");
  } catch {
    return { summary: String(content ?? "").trim() };
  }
};

// Returns { summary, topics, safety, provider } (summary null when the gate replaced it).
export async function summarizeSession({ turns }, env, { fetchFn = fetch, callFn = callBrain } = {}) {
  if (turns.some((t) => isCrisis(t.text))) return { summary: CRISIS_SUMMARY, topics: [], safety: "crisis", provider: null };
  const out = await callFn(
    [
      { role: "system", content: SYSTEM },
      { role: "user", content: JSON.stringify({ turns: turns.map((t) => ({ role: t.role, text: t.text })) }) },
    ],
    env,
    // 600 tokens: room for a reasoning model's preamble before the JSON (reasoning is off on the test path).
    { fetchFn, json: true, maxTokens: 600, timeoutMs: SUMMARY_TIMEOUT_MS, role: "summary" },
  );
  const o = parse(out.content);
  const summary = typeof o?.summary === "string" ? o.summary.trim().slice(0, MAX_SUMMARY) : "";
  const topics = (Array.isArray(o?.topics) ? o.topics : []).filter((t) => typeof t === "string").map((t) => t.slice(0, 40)).slice(0, 5);
  if (!summary) return { summary: null, topics: [], safety: "empty", provider: out.provider };
  if (gateText(summary) !== summary || topics.some((t) => gateText(t) !== t)) {
    return { summary: null, topics: [], safety: "replaced", provider: out.provider };
  }
  return { summary, topics, safety: "passed", provider: out.provider };
}
