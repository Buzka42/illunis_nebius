// Food calorie check for /log/parse (contract C6). Plain code only: queries Tavily for each item the user gave
// kcal for (at most 3 searches), reads the first kcal figure in the results, scales it to the user's quantity,
// and compares. A mismatch is never applied here: the caller returns it as a choice. No logging.
export const FOOD_CHECK_MAX = 3;
const KCAL_RE = /(\d{1,3}(?:,\d{3})+|\d+(?:[.,]\d+)?)\s*(?:kcal|calories)\b/i;
const MATCH_FLOOR = 25;
const MATCH_RATIO = 0.15;

// "1,200" is a thousands mark; "1,2" and "1.2" are decimals.
const parseKcal = (raw) => (/^\d{1,3}(?:,\d{3})+$/.test(raw) ? Number(raw.replace(/,/g, "")) : Number(raw.replace(",", ".")));

const bulk = (unit) => unit === "g" || unit === "ml";
const per100 = (item) => bulk(item.unit) && item.quantity !== undefined;

// Query per C6: per 100 g/ml for a stated gram or ml quantity, else per the unit (or serving).
export function foodQuery(item) {
  if (per100(item)) return `${item.name} calories per 100 ${item.unit}`;
  return `${item.name} calories per ${bulk(item.unit) || item.unit === undefined ? "serving" : item.unit}`;
}

// Factor from the found figure to the user's quantity.
const scaleOf = (item) => (per100(item) ? item.quantity / 100 : (item.quantity ?? 1));

// First result whose text states kcal or calories: { value (scaled, rounded), url, title } or null.
// A gram or millilitre item is only compared with a figure stated per 100 g or 100 ml, so a per-cup or
// per-piece number is never multiplied by the quantity (live check 2026-10-29: 205 kcal per cup became 410).
const PER_100 = /\b100\s*(?:g|grams?|ml|millilitres?|milliliters?)\b/i;
// The kcal figure must sit within 60 characters of a per-100 g or per-100 ml basis: a per-cup figure elsewhere in
// the same snippet is skipped.
const BASIS_100 = /(?:per|\/|for|every)\s*100\s*(?:g|grams?|ml|millilitres?|milliliters?)\b/i;
function kcalPer100(text) {
  const re = new RegExp(KCAL_RE.source, "gi");
  let m;
  while ((m = re.exec(text))) {
    const near = text.slice(Math.max(0, m.index - 40), m.index + m[0].length + 40);
    if (BASIS_100.test(near)) return m;
  }
  return null;
}
function pick(results, item) {
  const scale = scaleOf(item);
  // Every result that states a usable figure votes; the median is compared with the user's number, so one
  // wrong site cannot decide the check. The source shown is the result closest to the median.
  const votes = [];
  for (const r of results) {
    const text = String(r?.content ?? "");
    const m = per100(item) ? kcalPer100(text) : KCAL_RE.exec(text);
    if (!m) continue;
    const n = parseKcal(m[1]);
    if (!Number.isFinite(n)) continue;
    votes.push({ value: Math.round(n * scale), url: r.url, title: r.title });
  }
  if (!votes.length) return null;
  const sorted = [...votes].sort((a, b) => a.value - b.value);
  const median = sorted[Math.floor((sorted.length - 1) / 2)].value;
  const best = votes.reduce((a, b) => (Math.abs(b.value - median) < Math.abs(a.value - median) ? b : a));
  return { value: median, url: best.url, title: best.title };
}

export const kcalMatches = (user, found) => Math.abs(user - found) <= Math.max(MATCH_FLOOR, MATCH_RATIO * found);

async function checkItem(item, item_index, searchFn) {
  let results;
  try {
    results = (await searchFn(foodQuery(item))).results ?? [];
  } catch {
    return { item_index, status: "unverified" };
  }
  const found = pick(results, item);
  if (!found) return { item_index, status: "unverified" };
  const source = { source_url: found.url, source_title: found.title };
  if (kcalMatches(item.kcal, found.value)) return { item_index, status: "match", ...source };
  return { item_index, status: "mismatch", field: "kcal", user_value: item.kcal, found_value: found.value, ...source };
}

// Returns one row per checked item: status "match" | "unverified" | "mismatch" (mismatch rows carry the choice).
// searchFn(query) -> {results}; it may throw, which makes the item "unverified".
export async function foodCheck(entry, searchFn) {
  // Estimated items (kcal_estimated) were filled from the same search, so they are not checked again.
  const picks = (entry.items ?? []).map((item, i) => ({ item, i })).filter(({ item }) => item.kcal !== undefined && !item.kcal_estimated).slice(0, FOOD_CHECK_MAX);
  return Promise.all(picks.map(({ item, i }) => checkItem(item, i, searchFn)));
}

// Estimates for foods logged without a stated figure (owner, 2026-10-30): the same search and the same per-100 g
// rule. An estimate is written as kcal with kcal_estimated true and its source, never as a stated figure, so the
// phone can label it. Items with no usable figure stay without calories.
export async function estimateFood(entry, searchFn) {
  const todo = (entry.items ?? []).map((item, i) => ({ item, i })).filter(({ item }) => item.kcal === undefined && item.name).slice(0, FOOD_CHECK_MAX);
  const results = await Promise.all(todo.map(async ({ item, i }) => {
    let found = null;
    try {
      found = await searchFn(foodQuery(item));
    } catch {
      return { item_index: i, status: "unverified" };
    }
    const hit = pick(found?.results ?? found ?? [], item);
    if (!hit) return { item_index: i, status: "unverified" };
    item.kcal = hit.value;
    item.kcal_estimated = true;
    item.kcal_source = { source_url: hit.url, source_title: hit.title };
    return { item_index: i, status: "estimated", source_url: hit.url, source_title: hit.title };
  }));
  return results;
}
