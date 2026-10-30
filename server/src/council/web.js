// Web search for the council relay (contract C3). Meta's Responses web search first when Meta is usable,
// else Tavily, else null. Search failures return null (or fall through to the next source): the relay
// must still answer without web sources. Imports only providers/meta.js, providers/tavily.js and data-mode.js.
// Forums, video and social sites are never council sources (live run 2026-10-30 cited r/Fitness and a YouTube
// short for a stretching answer): Tavily is asked to leave them out, and any that still come back are dropped.
import { META_PROVIDER, metaConfigProblem, metaModel, webSearchMeta } from "../providers/meta.js";
import { searchTavily, tavilyConfigProblem } from "../providers/tavily.js";
import { dataModeProblem } from "../data-mode.js";

export const WEB_TEXT_MAX = 1200;
export const EXCLUDED_DOMAINS = Object.freeze([
  "reddit.com", "youtube.com", "youtu.be", "tiktok.com", "instagram.com", "facebook.com", "x.com", "twitter.com",
  "quora.com", "pinterest.com", "medium.com",
]);

const clip = (s) => String(s ?? "").trim().slice(0, WEB_TEXT_MAX);

// True for a URL on an excluded domain or one of its subdomains; an unparsable URL counts as excluded.
export function excludedSource(url) {
  let host;
  try {
    host = new URL(String(url)).hostname.toLowerCase().replace(/\.$/, "");
  } catch {
    return true;
  }
  return EXCLUDED_DOMAINS.some((d) => host === d || host.endsWith(`.${d}`));
}
const kept = (results) => (Array.isArray(results) ? results : []).filter((r) => !excludedSource(r?.url));

// Returns { text, results: [{title, url, content}], via: "meta" | "tavily" } or null.
export async function searchWeb(query, env = {}, { fetchFn = fetch, timeoutMs } = {}) {
  const metaOk = !metaConfigProblem(env) && !dataModeProblem(env, { provider: META_PROVIDER, model: metaModel(env), role: "council" });
  if (metaOk) {
    try {
      const got = await webSearchMeta(query, env, { fetchFn, timeoutMs });
      const text = clip(got?.text);
      if (text) return { text, results: kept(got.results).map((r) => ({ title: r.title, url: r.url, content: text })), via: "meta" };
    } catch {
      // Meta unavailable: try Tavily below.
    }
  }
  if (!tavilyConfigProblem(env, "council")) {
    try {
      const got = await searchTavily(query, env, { fetchFn, timeoutMs, role: "council", excludeDomains: EXCLUDED_DOMAINS });
      const results = kept(got.results);
      const text = clip(got.answer || results.map((r) => r.content).join(" "));
      if (text) return { text, results: results.map(({ title, url, content }) => ({ title, url, content })), via: "tavily" };
    } catch {
      return null;
    }
  }
  return null;
}
