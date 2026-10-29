# Nebius demo: seed, walkthrough and dry run

Status 2026-10-29. Runs on the Nebius slice (`docs/NEBIUS_TASKLIST.md`, T9 and T16). Deploy notes: `server/docs/SETUP.md`,
section "Nebius deploy". Items marked **pending merge** depend on packages P1 to P4 in `docs/NEBIUS_BUILD_PLAN.md`
and describe their contracts; they are not in code yet.

## 1. Synthetic seed

Everything in the seed is invented. It describes no real person.

Regenerate it from the repo root (the tool is not edited for this):

```
node tools/synthetic/gen_history.mjs --seed 2026 --end 2026-10-29 --out server/test/fixtures/nebius-demo
```

Flags (from the tool's header): `--seed` (integer, default 2026), `--end` (YYYY-MM-DD, default 2026-11-01 when not
given, so always pass it), `--out` (directory), `--stdout` (print instead of writing).

The output is `server/test/fixtures/nebius-demo/`:

- `synthetic_maya.json`, `synthetic_jonas.json`, `synthetic_priya.json`: three personas with a 30-day window ending
  2026-10-29. Each file holds `checkins`, `wearable`, `analysis_21d_body` (a `POST /analysis/21d` body for the last
  21 days), `sessions` (four session summaries) and `memory_notes` (the phone's memory-note shape, source `synthetic`).
- `demo-lines.json`: the typed lines for the walkthrough and the smoke test. It holds `chat` (plain lines), `big_question`,
  `food_match` (`banana 120 g 107 kcal`) and `food_mismatch` (`banana 120 g 400 kcal`).

Re-running the command with the same flags gives the same files, so a clean `git status` on the fixture is the check.

Phone side: there is no loader for the seed (open question 10, default). The demo types its lines by hand. The personas
feed the server tests and the analysis reference only.

## 2. Walkthrough

Build the client with text chat only: `ILLUNIS_VOICE=false`, `ILLUNIS_SERVER_URL`, `ILLUNIS_DEVICE_TOKEN` (T12). Point
it at the synthetic deploy (T10), or the dev Worker (owner_any) for a rehearsal. Use the seed lines in this order.

1. **Plain chat.** Type `plan my day around three meetings`. A normal reply comes back. The "not medical advice" line
   appears only when the reply touches health.
2. **Health-adjacent chat.** Type `I slept badly and feel flat today`. The reply is gated like any other. A repaired reply
   (pending merge, P1) answers with `safety: "repaired"`, and the app treats it as a normal answer.
3. **Council offer.** Type the big question, `why do I keep waking up at 3am every night`. The app offers the council.
   The offer is shown when the server's `council_suggested` is true (pending merge, P1: `/reply` and the stream send it).
   The client's own trigger also opens the offer, so the offer is present on current builds.
4. **Council answer.** Accept the offer. The answer shows the synthesis and its sources. Bank sources come from the four
   wellbeing banks (diet, training, breath_stress, sleep_lifestyle; pending merge, P3 ingest). Web sources come from
   Tavily when a bank is thin (pending merge, P1 and P2). Each source shows its title and host. Note the quota: the
   council allows 5 runs per day (`QUOTA_COUNCIL_PER_DAY`).
5. **Food, matching.** Log `banana 120 g 107 kcal` as food. The preview shows "Checked against <title>" (pending merge,
   P2 and P4). Then "Save? Yes / No"; answer yes.
6. **Food, mismatch.** Log `banana 120 g 400 kcal`. The app does not save it. It shows a choice: "You wrote 400 kcal.
   <source title> lists 107 kcal." with "Keep mine (400)" and "Use 107" (pending merge, P4; decision D-C). The source
   title and host are shown as text. Pick one. Typed answers `mine` and `source` also work. After the pick, the entry
   goes to the normal "Save? Yes / No" preview. Nothing is written before the yes.
7. **Other log views.** Open each structured log view in turn (already in main) and show the entries saved so far.
8. **Breathwork.** Start the guided breathwork (already in main) and run one round.

The numbers in steps 5 and 6 come from a live Tavily search, so the found value can differ from 107. The match rule
is `|user - found| <= max(25, 0.15 * found)`. Check the live value during the dry run and adjust the line if needed
(UNVERIFIED until the live check).

## 3. Dry-run checklist

Run it before recording the walkthrough (T16). Record each result with its date.

- [ ] `cd server && npm test`: all passing. Record the count (259 before this slice, plus each package's new tests).
- [ ] `node server/scripts/check-deploy.mjs`: prints "check-deploy: OK".
- [ ] The fixture regenerates with no diff (section 1 command, then `git status server/test/fixtures`).
- [ ] `node server/scripts/ingest-knowledge.mjs --dry-run --only diet,training,breath_stress,sleep_lifestyle` prints
      diet 8, training 7, breath_stress 8, sleep_lifestyle 7 (pending merge, P3).
- [ ] Smoke on the target Worker: `ILLUNIS_DEVICE_TOKEN=<token> node server/scripts/check-deploy.mjs --smoke https://<host>`.
      All six checks PASS. Save the output; it must contain no token and no model text.
- [ ] Client: `cd client && flutter analyze --no-pub && flutter test --no-pub` (analyze 0 issues).
- [ ] Walkthrough steps 1 to 8 run in order on the target Worker. Note any step that differs from this file.
- [ ] Secrets: `OPENCODE_API_KEY` and `OPENROUTER_API_KEY` deleted last, after the final smoke run (D-B).
