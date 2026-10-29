// /assistant/* routes: the bridge between the owner's phone and the Hermes `illunis` profile.
// Hackathon scope: one owner link. Only the device in ASSISTANT_OWNER_DEVICE_ID may use the device routes,
// and every inbox push lands in that device's AssistantInbox object. Multi-user pairing (a per-device link
// record, issued by a pairing flow and holding each user's Hermes URL and keys) is future work, for the VPS brain design
// (docs/DESIGN.md section 2.2).
//
// Bot output is untrusted data. Text the phone may speak (message replies, inbox items, the readback)
// goes through gateText; the readback is built here from the action itself, never taken from the bot, so the
// spoken sentence always matches what gets signed. Responses and logs carry fixed codes only.
import { createHash } from "node:crypto";
import { DEVICE_ID } from "../auth.js";
import { notConfigured } from "../council/provider.js";
import { gateText, isCrisis, passesGate, REFERRAL_TEXT, touchesHealth, withHealthLine } from "../safety.js";
import {
  APPROVAL_TTL_SECONDS, INBOX_MAX_BYTES, actionHash, signApproval, usableSecret, validateAction, validateInput, verifyInbox,
} from "./contract.js";
import { HermesError, callHermes, hermesConfigProblem } from "./hermes.js";
import { assistantStub } from "./store.js";

export const ASSISTANT_DEVICE_ROUTES = [
  "POST /assistant/message", "POST /assistant/memory/write", "POST /assistant/memory/recall",
  "POST /assistant/action/propose", "POST /assistant/action/confirm", "GET /assistant/inbox",
];
export const INBOX_PUSH_ROUTE = "POST /assistant/inbox";

const json = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
const bad = (detail) => json({ error: "bad_request", detail }, 400);
const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const nowSeconds = (ms) => Math.floor(ms / 1000);

function ownerProblem(env) {
  const id = env.ASSISTANT_OWNER_DEVICE_ID;
  if (typeof id !== "string" || !id) return "ASSISTANT_OWNER_DEVICE_ID missing";
  return DEVICE_ID.test(id) ? null : "ASSISTANT_OWNER_DEVICE_ID invalid";
}
const doProblem = (env) => (env.ASSISTANT_DO?.idFromName ? null : "ASSISTANT_DO binding missing");
const secretProblem = (env) => (usableSecret(env.ILLUNIS_INBOX_SECRET) ? null : "ILLUNIS_INBOX_SECRET missing or shorter than 32 characters");
const firstProblem = (...ps) => ps.find(Boolean) ?? null;
const notConfiguredResponse = (detail) => json({ error: "not_configured", detail }, 503);

// Maps a HermesError to the phone's answer. The bot's own error message is never passed on.
function hermesFailure(err) {
  if (err?.message === "not configured") return notConfiguredResponse(err.detail ?? "not configured");
  if (!(err instanceof HermesError)) return json({ error: "upstream_error" }, 502);
  if (err.code === "hermes_refused") return json({ error: "assistant_refused", code: err.botCode }, 422);
  if (err.code === "hermes_timeout") return json({ error: "assistant_timeout" }, 504);
  return json({ error: "assistant_unavailable", code: err.code }, 502);
}

async function readCapped(request, max) {
  const declared = Number(request.headers.get("Content-Length"));
  if (Number.isFinite(declared) && declared > max) return null;
  if (!request.body) return new Uint8Array(0);
  const reader = request.body.getReader();
  const chunks = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > max) {
      await reader.cancel().catch(() => {});
      return null;
    }
    chunks.push(value);
  }
  const out = new Uint8Array(total);
  let at = 0;
  for (const c of chunks) {
    out.set(c, at);
    at += c.byteLength;
  }
  return out;
}

// POST /assistant/inbox from Hermes. Not device-token authenticated: the HMAC is the credential.
export async function handleInboxPush(request, env, { now, logger }) {
  const problem = firstProblem(secretProblem(env), ownerProblem(env), doProblem(env));
  if (problem) return notConfiguredResponse(problem);
  const raw = await readCapped(request, INBOX_MAX_BYTES);
  if (!raw) return json({ error: "too_large" }, 413);
  const nowS = nowSeconds(now);
  const out = verifyInbox(env.ILLUNIS_INBOX_SECRET, raw, request.headers, nowS);
  if (out.code) {
    logger.warn("inbox_rejected", out.code);
    return json({ error: out.code === "bad_signature" ? "unauthorized" : "bad_request", code: out.code }, out.code === "bad_signature" ? 401 : 400);
  }
  let stored;
  try {
    stored = await assistantStub(env.ASSISTANT_DO, env.ASSISTANT_OWNER_DEVICE_ID).push(out.item, nowS);
  } catch {
    logger.error("inbox_store_error");
    return json({ error: "inbox_unavailable" }, 503);
  }
  if (stored.code === "replay") {
    logger.warn("inbox_rejected", "replay");
    return json({ error: "replay" }, 409);
  }
  if (stored.code) return json({ error: stored.code }, 507);
  return json({ accepted: true, id: stored.id }, 202);
}

// Readback built from the action, so what the user hears is exactly what gets signed.
export const readbackFor = (action) => `I will message ${action.target}: ${action.text}`;

const newActionId = () => `act_${crypto.randomUUID().replaceAll("-", "")}`;

// Device routes. The caller has authenticated deviceId and charged its quota.
export async function handleAssistant(key, request, env, deviceId, { fetchFn, now, logger }) {
  const owner = ownerProblem(env);
  if (owner) return notConfiguredResponse(owner);
  if (deviceId !== env.ASSISTANT_OWNER_DEVICE_ID) return json({ error: "assistant_not_linked" }, 403);
  const opts = { fetchFn };
  const nowS = nowSeconds(now);

  if (key === "GET /assistant/inbox") {
    const problem = doProblem(env);
    if (problem) return notConfiguredResponse(problem);
    const limit = Number(new URL(request.url).searchParams.get("limit") ?? 20);
    try {
      const { items, more } = await assistantStub(env.ASSISTANT_DO, deviceId).take(Number.isInteger(limit) ? limit : 20);
      // Inbox text comes from the bot: gate it before the phone can speak it.
      return json({ items: items.map((i) => ({ id: i.id, kind: i.kind, text: gateText(i.text), ts: i.ts })), more });
    } catch {
      logger.error("inbox_store_error");
      return json({ error: "inbox_unavailable" }, 503);
    }
  }

  let body;
  try {
    body = await request.json();
  } catch {
    return bad("invalid json");
  }
  if (!isObj(body)) return bad("invalid json");

  try {
    if (key === "POST /assistant/message") {
      const input = { text: body.text, ...(body.context !== undefined ? { context: body.context } : {}) };
      const problems = validateInput("message", input);
      if (problems.length) return bad(problems[0]);
      if (isCrisis(input.text)) return json({ text: REFERRAL_TEXT, safety: "crisis" });
      const result = await callHermes("message", input, env, opts);
      const gated = gateText(result.text);
      const health = touchesHealth({ texts: [input.text, result.text] });
      return json({
        text: health && gated !== REFERRAL_TEXT ? withHealthLine(gated) : gated,
        safety: gated === result.text ? "passed" : "replaced",
        health,
      });
    }
    if (key === "POST /assistant/memory/write") {
      // The phone sends expires_at: null for notes that never expire; the contract wants it omitted.
      const input = Object.fromEntries(["kind", "text", "confidence", "expires_at"].filter((k) => body[k] !== undefined && body[k] !== null).map((k) => [k, body[k]]));
      const problems = validateInput("memory_write", input);
      if (problems.length) return bad(problems[0]);
      return json(await callHermes("memory_write", input, env, opts));
    }
    if (key === "POST /assistant/memory/recall") {
      const input = { query: body.query ?? "", ...(body.limit !== undefined ? { limit: body.limit } : {}) };
      const problems = validateInput("memory_recall", input);
      if (problems.length) return bad(problems[0]);
      // Items are the owner's notes, returned as data for the phone's context, not as speech.
      return json(await callHermes("memory_recall", input, env, opts));
    }
    if (key === "POST /assistant/action/propose") {
      const problem = firstProblem(hermesConfigProblem(env), secretProblem(env), doProblem(env));
      if (problem) throw notConfigured(problem);
      const input = { request: body.request };
      const problems = validateInput("action_propose", input);
      if (problems.length) return bad(problems[0]);
      if (isCrisis(input.request)) return json({ error: "action_refused", code: "crisis", text: REFERRAL_TEXT }, 422);
      const { action } = await callHermes("action_propose", input, env, opts);
      const readback = readbackFor(action);
      if (isCrisis(action.text) || !passesGate(readback)) {
        logger.warn("assistant_action_refused", deviceId, "gate");
        return json({ error: "action_refused", code: "gate" }, 422);
      }
      const actionId = newActionId();
      const { expires_at } = await assistantStub(env.ASSISTANT_DO, deviceId).propose(actionId, action, actionHash(action), nowS);
      return json({ action_id: actionId, readback, expires_in: expires_at - nowS });
    }
    if (key === "POST /assistant/action/confirm") {
      const problem = firstProblem(hermesConfigProblem(env), secretProblem(env), doProblem(env));
      if (problem) throw notConfigured(problem);
      const keys = Object.keys(body);
      if (keys.some((k) => k !== "action_id" && k !== "confirm_phrase_heard")) return bad("only action_id and confirm_phrase_heard allowed");
      if (body.confirm_phrase_heard !== true) return bad("confirm_phrase_heard must be true");
      if (typeof body.action_id !== "string" || !/^act_[0-9a-f]{32}$/.test(body.action_id)) return bad("action_id invalid");
      const claimed = await assistantStub(env.ASSISTANT_DO, deviceId).claim(body.action_id, nowS);
      if (claimed.code === "action_expired") return json({ error: "action_expired" }, 410);
      if (claimed.code) return json({ error: "action_unknown" }, 404);
      const { action } = claimed;
      // Integrity: the stored action must still hash to what was stored with it.
      if (validateAction(action).length || actionHash(action) !== claimed.action_hash) return json({ error: "action_unknown" }, 404);
      const expiresAt = nowS + APPROVAL_TTL_SECONDS;
      const approval = { action_id: body.action_id, expires_at: expiresAt, sig: signApproval(env.ILLUNIS_INBOX_SECRET, body.action_id, action, expiresAt) };
      const idem = `exec_${createHash("sha256").update(body.action_id).digest("hex").slice(0, 32)}`;
      const result = await callHermes("action_execute", { action, approval }, env, { ...opts, idempotencyKey: idem });
      if (result.action_id !== body.action_id) throw new HermesError("hermes_contract");
      // detail is bot text; it is not spoken, and only passes when it clears the gate.
      const detail = typeof result.detail === "string" && result.detail && passesGate(result.detail) ? { detail: result.detail } : {};
      return json({ action_id: result.action_id, status: result.status, ...detail });
    }
    return json({ error: "not_found" }, 404);
  } catch (err) {
    logger.error("route_error", key.split(" ")[1], deviceId, err instanceof HermesError ? err.code : err?.message === "not configured" ? "not_configured" : "upstream_error");
    return hermesFailure(err);
  }
}
