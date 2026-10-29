// Web search for the council relay (contract C3). Meta's Responses web search first when Meta is usable,
// else Tavily, else null. Search failures return null (or fall through to the next source): the relay
// must still answer without web sources. Imports only providers/meta.js, providers/tavily.js and data-mode.js.
import { META_PROVIDER, metaConfigProblem, metaModel, webSearchMeta } from "../providers/meta.js";
import { searchTavily, tavilyConfigProblem } from "../providers/tavily.js";
import { dataModeProblem } from "../data-mode.js";

export const WEB_TEXT_MAX = 1200;

const clip = (s) => String(s ?? "").trim().slice(0, WEB_TEXT_MAX);

// Returns { text, results: [{title, url, content}] } or null.
export async function searchWeb(query, env = {}, { fetchFn = fetch, timeoutMs } = {}) {
  const metaOk = !metaConfigProblem(env) && !dataModeProblem(env, { provider: META_PROVIDER, model: metaModel(env), role: "council" });
  if (metaOk) {
    try {
      const got = await webSearchMeta(query, env, { fetchFn, timeoutMs });
      const text = clip(got?.text);
      if (text) return { text, results: (got.results ?? []).map((r) => ({ title: r.title, url: r.url, content: text })) };
    } catch {
      // Meta unavailable: try Tavily below.
    }
  }
  if (!tavilyConfigProblem(env, "council")) {
    try {
      const got = await searchTavily(query, env, { fetchFn, timeoutMs, role: "council" });
      const text = clip(got.answer || got.results.map((r) => r.content).join(" "));
      if (text) return { text, results: got.results.map(({ title, url, content }) => ({ title, url, content })) };
    } catch {
      return null;
    }
  }
  return null;
}
