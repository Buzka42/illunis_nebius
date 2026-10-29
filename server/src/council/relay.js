// Council v2 relay. One main model (the relay) holds a single tool, consult(expert_id, question), and may call
// it several times, including follow-ups between experts. Experts answer the relay in JSON; their text reaches
// the user only through the relay's synthesis. Plain code enforces every bound and gate:
//   - crisis text gets the fixed referral before any call;
//   - at most LIMITS.maxConsults consults, LIMITS.perExpert per expert, and a wall-clock time limit;
//   - an expert point survives only if it cites at least one source and every source id it cites was retrieved
//     for that consult (all kinds, decision 2026-10-29);
//   - the synthesis passes the gate with at most one repair call (contract C4), only when at least
//     LIMITS.repairMinMs remain; the result carries gate "passed" | "repaired" | "replaced";
//   - medical runs (the relay's JSON `medical` flag, or a medical expert consulted) append NOT_MEDICAL_ADVICE and the
//     clinician path; other runs get no line (no keyword matching, owner decision 2026-10-29).
// Web search (contract C3, searchWeb in council/web.js): a thin bank (fewer than THIN_BANK distinct sources) gets
// one search before the expert call, and its results become sources the expert may cite; an expert may also ask
// for a search after answering. Only this relay runs searches, at most LIMITS.maxSearches per run, kind "web".
// Nothing here logs; errors carry fixed codes.
import {
  CLINICIAN_PATH, GATE_RULE_PROMPT, HEALTH_HARM_SCOPE, HEALTH_WELLBEING_SCOPE, NOT_MEDICAL_ADVICE, REFERRAL_TEXT, gateWithRepair,
  isCrisis, repairInstruction,
} from "../safety.js";
import { activeExperts, activeExpertIds, getExpert, isActive, isMedical } from "./experts.js";
import { brainConfigProblem, callBrain, notConfigured } from "./provider.js";
import { retrieve } from "../knowledge/retrieve.js";
import { ProviderError } from "../providers/chat.js";
import { searchWeb } from "./web.js";

// Voice budget (2026-10-25): the whole run fits in timeLimitMs; consults stop finalReserveMs before the deadline so
// the relay always gets its closing call. parallel: consults asked in one relay turn run this many at a time.
export const LIMITS = Object.freeze({
  maxConsults: 8, perExpert: 3, timeLimitMs: 45_000, callTimeoutMs: 20_000, finalReserveMs: 8_000, maxSearches: 2, parallel: 4,
  repairMinMs: 2_000,
});
// A bank with fewer distinct sources than this gets a web search before the expert call.
export const THIN_BANK = 2;
const MAX_WEB_TEXT = 1500;
const NO_ANSWER = "The council could not finish an answer this time.";
// A 4xx on a tools request means the endpoint does not take tools: the relay then plans its consults in JSON.
const TOOLS_REFUSED = new Set([400, 404, 422]);
const PLAN_PROMPT =
  'Tools are unavailable. Reply with JSON only: {"consult":[{"expert_id":string,"question":string}]} naming the one ' +
  'to four most relevant experts by id, or {"consult":[]} if none is needed.';
export const PURPOSES = ["chat", "digest", "analysis"];
const MAX_SYNTHESIS = 2000;
const MAX_POINT = 400;

// The consult tool for this deploy: its enum lists only the experts the flags leave on (experts.js activeExperts).
export const consultTool = (env = {}) => ({
  type: "function",
  function: {
    name: "consult",
    description: "Ask one council expert a focused question. Returns the expert's points with source ids.",
    parameters: {
      type: "object",
      properties: {
        expert_id: { type: "string", enum: activeExpertIds(env) },
        question: { type: "string", description: "A focused question with only the context the expert needs." },
      },
      required: ["expert_id", "question"],
    },
  },
});

const PURPOSE_LINES = {
  chat: "The user asked a big question in conversation. Answer it in three to six short spoken sentences.",
  digest: "This is the morning digest. Give two to four short spoken sentences: what stands out and one gentle option.",
  analysis:
    "This is a comment on 21-day findings. Use only numbers that appear in the findings, exactly as written. " +
    "Do not name causes, conditions or conclusions; call them tentative observations from check-ins.",
};

export function relaySystem(purpose, env = {}) {
  const roster = activeExperts(env).map((e) => `- ${e.id} (${e.kind}): ${e.field}; ${e.scope}`).join("\n");
  return [
    "You are the relay of the Illunis wellbeing council. You may consult these experts with the consult tool:",
    roster,
    "Consult the one to four most relevant experts, with follow-ups between them if their points conflict. " +
      `At most ${LIMITS.maxConsults} consults in total and ${LIMITS.perExpert} per expert.`,
    "Medical experts give general information only. Never give medicine doses. Describe observations and options; " +
      `the user decides. ${GATE_RULE_PROMPT}`,
    PURPOSE_LINES[purpose] ?? PURPOSE_LINES.chat,
    'When done, reply with JSON only: {"synthesis":string,"experts_consulted":[string],"sources":[string source ids ' +
      `you relied on],"medical":boolean}. Set medical true only when the answer gives ${HEALTH_HARM_SCOPE}. ` +
      `Set it false for ${HEALTH_WELLBEING_SCOPE}. Never write a medical disclaimer yourself.`,
  ].join("\n\n");
}

const clip = (v, n) => (typeof v === "string" ? v.slice(0, n) : "");
const jsonIn = (text) => {
  const m = String(text ?? "").replace(/<think>[\s\S]*?<\/think>/gi, "").match(/\{[\s\S]*\}/);
  try {
    return m ? JSON.parse(m[0]) : null;
  } catch {
    return null;
  }
};

// Expert reply contract: {points:[{text, source_ids:[]}], caveats:[], confidence, search_query?}.
export function parseExpert(content) {
  const o = jsonIn(content) ?? {};
  const points = (Array.isArray(o.points) ? o.points : [])
    .filter((p) => typeof p?.text === "string" && p.text.trim())
    .map((p) => ({
      text: p.text.trim().slice(0, MAX_POINT),
      source_ids: Array.isArray(p.source_ids) ? p.source_ids.filter((s) => typeof s === "string") : [],
    }));
  const caveats = (Array.isArray(o.caveats) ? o.caveats : []).filter((c) => typeof c === "string").map((c) => c.slice(0, MAX_POINT));
  const c = Number(o.confidence);
  const confidence = Number.isFinite(c) ? Math.min(1, Math.max(0, c)) : 0;
  const search_query = typeof o.search_query === "string" && o.search_query.trim() ? o.search_query.trim().slice(0, 200) : null;
  return { points: points.slice(0, 6), caveats: caveats.slice(0, 4), confidence, search_query };
}

// Source filter (decision 2026-10-29, META_SLICE 2026-10-26): every point must cite at least one retrieved source,
// for every expert kind. A point that cites any id outside the retrieved set is dropped too.
export function filterPoints(points, retrievedIds) {
  return points.filter((p) => p.source_ids.length > 0 && p.source_ids.every((id) => retrievedIds.has(id)));
}

export function parseFinal(content) {
  const o = jsonIn(content);
  if (!o || typeof o.synthesis !== "string") return { synthesis: String(content ?? "").trim(), sources: [], medical: false };
  const sources = (Array.isArray(o.sources) ? o.sources : []).map((s) => (typeof s === "string" ? s : s?.id)).filter((s) => typeof s === "string");
  return { synthesis: o.synthesis.trim(), sources, medical: o.medical === true };
}

export const crisisResult = (purpose) => ({
  synthesis: REFERRAL_TEXT, experts_consulted: [], sources: [], medical: false, crisis: true, purpose, providers: [], advise_only: true,
});

// Appends the medical lines once each, after the gate so the gate can never remove them.
export function withMedicalLines(text) {
  const withAdvice = text.includes(NOT_MEDICAL_ADVICE) ? text : `${text} ${NOT_MEDICAL_ADVICE}`;
  return withAdvice.includes(CLINICIAN_PATH) ? withAdvice : `${withAdvice} ${CLINICIAN_PATH}`;
}

// input: {question, context?: {short_term_summary?, signals?, findings?}, purpose}
// deps: fetchFn, now, limits, retrieveFn, callFn, searchFn (all injectable for tests).
export async function runCouncilV2(input, env = {}, deps = {}) {
  const { fetchFn = fetch, now = Date.now, retrieveFn = retrieve, callFn = callBrain, searchFn = searchWeb } = deps;
  const limits = { ...LIMITS, ...(deps.limits ?? {}) };
  const purpose = PURPOSES.includes(input.purpose) ? input.purpose : "chat";
  const context = input.context ?? {};
  if ([input.question, context.short_term_summary].some((t) => isCrisis(t))) return crisisResult(purpose);
  const problem = brainConfigProblem(env);
  if (problem) throw notConfigured(problem);

  const deadline = now() + limits.timeLimitMs;
  const remaining = () => deadline - now();
  // reserve: time kept back for later calls (the closing synthesis).
  const timeoutMs = (reserve = 0) => Math.max(1, Math.min(remaining() - reserve, limits.callTimeoutMs));
  const consultOpen = () => remaining() > limits.finalReserveMs;
  const state = { consults: 0, perExpert: new Map(), consulted: [], sources: new Map(), cited: new Set(), given: new Set(), providers: new Set(), searches: 0, hits: new Set(), codes: new Set(), calls: [] };
  // state.calls: "<role>:<ms>:<ok|code>" per model call, fixed values only, for the route log.
  const ask = async (messages, opts, reserve = 0) => {
    const t0 = now();
    const mark = (r) => state.calls.push(`${opts.role ?? "relay"}:${now() - t0}:${r}`);
    try {
      const out = await callFn(messages, env, { fetchFn, timeoutMs: timeoutMs(reserve), ...opts });
      state.providers.add(out.provider);
      mark("ok");
      return out;
    } catch (err) {
      // Fixed codes only (ProviderError), for the route log.
      if (err instanceof ProviderError) state.codes.add(`${err.code}:${err.status ?? "-"}:${err.finish ?? err.limit ?? "-"}`);
      mark(err instanceof ProviderError ? err.code : "error");
      throw err;
    }
  };

  async function consult(call) {
    let args;
    try {
      args = JSON.parse(call.arguments);
    } catch {
      return { error: "bad_arguments" };
    }
    const expert = getExpert(args?.expert_id);
    const q = clip(args?.question, 1000).trim();
    if (call.name !== "consult" || !expert || !q) return { error: "unknown_expert_or_question" };
    // Registered but switched off by a flag: refused before any count, retrieval or call.
    if (!isActive(expert.id, env)) return { error: "expert_inactive" };
    if (state.consults >= limits.maxConsults) return limitHit("consult_limit");
    if ((state.perExpert.get(expert.id) ?? 0) >= limits.perExpert) return limitHit("expert_limit");
    if (!consultOpen()) return limitHit("time_limit");
    state.consults += 1;
    state.perExpert.set(expert.id, (state.perExpert.get(expert.id) ?? 0) + 1);
    if (!state.consulted.includes(expert.id)) state.consulted.push(expert.id);

    const { passages } = await retrieveFn(expert.bank, q, env, { k: 5, fetchFn });
    const retrieved = new Set();
    const given = [];
    for (const p of passages ?? []) {
      if (!retrieved.has(p.source_id)) given.push({ id: p.source_id, title: p.title, text: p.text });
      else given.find((g) => g.id === p.source_id).text += `\n${p.text}`;
      retrieved.add(p.source_id);
      if (!state.sources.has(p.source_id)) state.sources.set(p.source_id, { id: p.source_id, title: p.title, url: p.url, kind: "bank" });
    }
    // Thin bank: one web search before the expert call; its results are sources the expert may cite.
    // The counter is checked and raised with no await in between, so parallel consults keep the bound.
    if (retrieved.size < THIN_BANK && state.searches < limits.maxSearches && consultOpen()) {
      const found = await webSources(q, ++state.searches);
      for (const g of found.given ?? []) {
        given.push(g);
        retrieved.add(g.id);
      }
    }
    retrieved.forEach((id) => state.given.add(id));
    let reply;
    try {
      reply = await ask(
        [
          { role: "system", content: expert.systemPrompt },
          { role: "user", content: JSON.stringify({ question: q, sources: given }) },
        ],
        { json: true, maxTokens: 800, role: "expert" },
        limits.finalReserveMs,
      );
    } catch (err) {
      if (err?.message === "not configured") throw err;
      return { expert_id: expert.id, error: "expert_unavailable" };
    }
    const parsed = parseExpert(reply.content);
    const points = filterPoints(parsed.points, retrieved);
    for (const p of points) p.source_ids.forEach((id) => state.cited.add(id));
    const out = { expert_id: expert.id, field: expert.field, points, caveats: parsed.caveats, confidence: parsed.confidence };
    if (parsed.search_query && state.searches < limits.maxSearches && consultOpen()) {
      const { given: _given, ...web } = await webSources(parsed.search_query, ++state.searches);
      out.web = web;
    }
    return out;
  }

  function limitHit(code) {
    state.hits.add(code);
    return { error: code };
  }

  // n: this search's number, taken before the await. Ids are "web:<n>.<i>".
  // Returns { summary, sources, given } or { error }. given: the results as expert sources {id, title, text}.
  async function webSources(query, n) {
    let found;
    try {
      found = await searchFn(query, env, { fetchFn, timeoutMs: timeoutMs(limits.finalReserveMs) });
    } catch {
      return { error: "web_search_failed" };
    }
    if (!found) return { error: "web_search_unavailable" };
    const results = Array.isArray(found.results) ? found.results : [];
    const given = [];
    const sources = results.map((r, i) => {
      const id = `web:${n}.${i + 1}`;
      state.sources.set(id, { id, title: r.title, url: r.url, kind: "web" });
      given.push({ id, title: r.title, text: clip(r.content, MAX_WEB_TEXT) });
      return { id, title: r.title, url: r.url };
    });
    return { summary: clip(found.text, 1200), sources, given };
  }

  const messages = [
    { role: "system", content: relaySystem(purpose, env) },
    {
      role: "user",
      content: JSON.stringify({
        question: clip(input.question, 2000),
        purpose,
        context: {
          short_term_summary: clip(context.short_term_summary, 2000) || null,
          signals: context.signals ?? null,
          findings: context.findings ?? null,
        },
      }),
    },
  ];

  // Consults asked in one relay turn run in parallel, limits.parallel at a time. consult() counts and gates
  // synchronously before its first await, so the bounds hold in call order.
  async function consultAll(calls) {
    const results = [];
    for (let i = 0; i < calls.length; i += limits.parallel) {
      results.push(...(await Promise.all(calls.slice(i, i + limits.parallel).map(consult))));
    }
    return results;
  }

  // JSON-plan relay: used when the endpoint refuses tools. One plan call, parallel consults, then the closing call.
  async function planConsults() {
    messages.push({ role: "user", content: PLAN_PROMPT });
    const plan = jsonIn((await ask(messages, { json: true, maxTokens: 400, role: "relay" }, limits.finalReserveMs)).content);
    const items = (Array.isArray(plan?.consult) ? plan.consult : []).slice(0, limits.maxConsults);
    const calls = items.map((c, i) => ({ id: `plan${i}`, name: "consult", arguments: JSON.stringify(c ?? {}) }));
    const results = await consultAll(calls);
    messages.push({ role: "assistant", content: JSON.stringify(plan ?? {}) });
    messages.push({ role: "user", content: JSON.stringify({ consult_results: results }) });
  }

  const tool = consultTool(env);
  let final = null;
  for (let turn = 0; turn < limits.maxConsults + 2 && consultOpen(); turn++) {
    const toolsOpen = state.consults < limits.maxConsults;
    let resp;
    try {
      resp = await ask(messages, toolsOpen ? { tools: [tool], maxTokens: 1200, role: "relay" } : { json: true, maxTokens: 1200, role: "relay" }, limits.finalReserveMs);
    } catch (err) {
      if (err?.message === "not configured") throw err;
      if (turn === 0 && toolsOpen && TOOLS_REFUSED.has(err?.status)) {
        state.hits.add("tools_unsupported");
        await planConsults();
        break;
      }
      // The first turn failing means the relay is down: a 502. Later failures still get the closing call.
      if (turn === 0) throw err;
      break;
    }
    if (!toolsOpen || !resp.tool_calls.length) {
      final = parseFinal(resp.content);
      break;
    }
    messages.push({
      role: "assistant",
      content: resp.content || null,
      tool_calls: resp.tool_calls.map((c) => ({ id: c.id, type: "function", function: { name: c.name, arguments: c.arguments } })),
    });
    const results = await consultAll(resp.tool_calls);
    resp.tool_calls.forEach((call, i) => messages.push({ role: "tool", tool_call_id: call.id, content: JSON.stringify(results[i]) }));
  }
  if (!final) {
    if (!consultOpen()) state.hits.add("time_limit");
    // Bounds or the consult window reached: one closing call without tools, in the reserved time.
    messages.push({ role: "user", content: "Consultation is closed. Reply now with the final JSON only." });
    try {
      if (remaining() > 0) final = parseFinal((await ask(messages, { json: true, maxTokens: 1200, role: "relay" })).content);
    } catch (err) {
      if (err?.message === "not configured") throw err;
      state.hits.add("relay_unavailable");
    }
  }
  if (!final?.synthesis) state.hits.add("no_synthesis");

  // Gate with one repair call (contract C4). Under repairMinMs left there is no call: the safe fallback.
  const text = clip(final?.synthesis, MAX_SYNTHESIS).trim() || NO_ANSWER;
  const gated = await gateWithRepair(text, async (rule) => {
    if (remaining() < limits.repairMinMs) throw new Error("no time for repair");
    const out = await ask(
      [
        { role: "system", content: relaySystem(purpose, env) },
        { role: "assistant", content: JSON.stringify({ synthesis: text }) },
        { role: "user", content: `${repairInstruction(rule)} Reply with JSON only: {"synthesis":string}.` },
      ],
      { json: true, maxTokens: 800, role: "repair" },
    );
    return clip(parseFinal(out.content).synthesis, MAX_SYNTHESIS);
  });
  if (gated.safety === "repaired") state.hits.add("gate_repaired");
  if (gated.safety === "replaced") state.hits.add("gate_replaced");
  return assemble(final, gated, state, purpose);
}

// gated: { text, safety } from the synthesis gate. The relay's medical flag (or a medical expert) decides the lines.
function assemble(final, gated, state, purpose) {
  const medical = final?.medical === true || state.consulted.some(isMedical);
  const synthesis = medical ? withMedicalLines(gated.text) : gated.text;
  // Sources: only ids that were really retrieved or searched; the model's list wins when it names any.
  const named = (final?.sources ?? []).filter((id) => state.sources.has(id));
  // Fallback (decision 2026-10-29, live run): when no point survives, the sources the experts were shown are listed,
  // so the user still sees what the council drew on. Web sources always count.
  const webIds = [...state.sources.keys()].filter((id) => id.startsWith("web:"));
  const ids = named.length ? named : [...state.cited, ...webIds].length ? [...state.cited, ...webIds] : [...state.given];
  const sources = [...new Set(ids)].map((id) => state.sources.get(id));
  return {
    synthesis,
    experts_consulted: [...state.consulted],
    sources,
    medical,
    purpose,
    providers: [...state.providers],
    consults: state.consults,
    limits_hit: [...state.hits],
    gate: gated.safety,
    advise_only: true,
    upstream_codes: [...state.codes],
    upstream_calls: state.calls,
  };
}
