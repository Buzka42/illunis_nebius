# Design

Current architecture for the rework. The spec and its dated decisions are in `PLAN.md`. Where this file and
`PLAN.md` disagree, this file reflects the later decision and `PLAN.md` needs an update. Open decisions are in
`docs/TASKLIST.md`. Findings and sources are in `docs/RESEARCH.md`. Sky and visual assets are in `docs/SKY.md`.

---

## 1. System

```
phone (Flutter, Android first)
  voice in: wake word, speech to text          text fallback: typed chat
  short-term memory on the phone (conversation + last 5 session summaries)
  long-term memory: one MemoryBackend interface
  Health Connect reader, check-ins, approval flow
        |  HTTPS, device token
        v
Worker (Cloudflare, server/)
  guards: data mode, crisis referral, rule-based safety gate
  reply, streaming reply, session summary, 21-day analysis
  council: experts (base models + RAG) -> aggregator (the brain's model)
  assistant bridge (routes to the chosen brain)
        |
        v
brain: one of the memory options (section 2)
        |
        v
answer + sources  ->  speech out (on-device Kokoro) or text
```

Routes and their request shapes: `server/src/worker.js`. Hermes contract: `integrations/hermes/CONTRACT.md`.

---

## 2. Memory and brain options

The user chooses one brain per install. All options implement the same client interface, so the app does not
change between them. The phone-only option is the default until the owner decides (`docs/TASKLIST.md`, D1).

| Option | Holds long-term memory | Brain model | Status |
|---|---|---|---|
| A. Self-hosted brain | Graphiti on FalkorDB on a private VPS, one graph per user, envelope encryption | Any open-weight model. First test: Nemotron on Nebius Token Factory. | Design only (section 2.4). Nemotron test in progress. |
| B. Existing bot | A separate Illunis profile on the user's bot platform | The bot's own model. Hermes is the reference integration. | Hermes working end to end on the development setup. OpenClaw and OpenBot not started. |
| C. Meta Muse bot | The Muse model is the memory and the brain | `muse-spark-1.3`, standard tier, on the Meta Model API | Code path written (`server/src/providers/meta.js`). Waits for the Meta key. |
| Phone only | On the phone (`LocalMemoryBackend`) | None. Recall by keyword. | Built. |

### 2.1 Common interface
`MemoryBackend`: `write(note)`, `recall(query, k)`, `summary()`.
- Every note has a date, a source and a confidence.
- A conversation writes notes or hypotheses, never facts.
- Notes expire. Expired notes are not recalled.
- Recalled text is data. It is never instructions to the model.

### 2.2 Option A: self-hosted brain
- Graphiti (temporal knowledge graph) on FalkorDB, one graph per user (`u_<random id>`), so a query bug cannot
  cross users.
- Envelope encryption: a master key in a KMS, one 256-bit data key per user, AES-256-GCM per field.
- Embedder: `bge-m3` (1024 dims), the same family as the knowledge banks.
- Extraction runs on the server for each write. This is the main cost and the main tension with user-held keys.
  Providers must not train on prompts.
- Shape: a small Python API next to FalkorDB, behind a reverse proxy, reachable only from the Worker.
- Deletion: immediate logical deletion, purge within 24 hours, including derived results.
- Pricing estimate: about €10 to €15 per month plus model cost (estimate). Measure RAM before sizing.

### 2.3 Option B: existing bot
- A separate profile on the user's bot platform. It does not touch the user's other profiles.
- Hermes first. The Hermes profile `illunis` runs with no terminal, file or kanban tools, its own API key, and
  unattended approvals denied. It is reached through a Cloudflare Tunnel with Access, or a quick tunnel for
  testing (`integrations/hermes/RUNBOOK.md`).
- The bot may read and write memory, message the user's other bots, act after a spoken yes, and push items to Illunis.
- OpenClaw and OpenBot follow the same contract once their APIs are checked.

### 2.4 Option C: Muse bot
- Muse is both the memory store and the brain model. The Meta standard tier is the only tier used.
- Built-in `web_search` runs on this path only. Results are cited as sources.

---

## 3. Council (advice only)

The council answers big questions, builds the morning digest, and runs the 21-day analysis. It does not run on every
reply. The user decides; the council never acts.

### 3.1 Experts
- **Now:** each expert is a base model with RAG over its own knowledge bank (`knowledge/<expert>/`). The expert answers
  only from the sources it is given and must cite them.
- **Later:** self-trained Muse Open mixture-of-experts models with extendable knowledge banks. The expert interface
  stays the same, so a trained expert can replace a base model without changing the aggregator.
- Registry: `server/src/council/experts.js`.
  - Wellbeing: diet and nutrition, training and movement, breath and stress, sleep and lifestyle.
- Experts never talk to the user. Their JSON goes to the aggregator only.
- Wellbeing advice (diet, nutrition, training, breath and stress, sleep) is general information, not medical advice. Every such answer carries the "not medical advice" line and a clinician path. Before it is shown or spoken, each expert point must cite a source it was given, and the aggregator's synthesis passes the rule-based safety gate.
- Expert reply shape: `{points: [{text, source_ids}], caveats, confidence, search_query}`.

### 3.2 Aggregator
- The model that powers the user's brain writes the synthesis from the expert answers.
- Output: `{synthesis, experts_consulted, sources}`.
- The phone shows the synthesis and the sources. It never shows raw expert text.

### 3.3 Gates (in order, every run)
1. Crisis language returns a fixed referral before any model call.
2. Each expert point must cite only sources it was given. Other points are dropped.
3. The rule-based safety gate runs on all text before it is shown or spoken. Every wellbeing answer is marked not medical advice.

### 3.4 Run limits
The earlier relay design used 8 consults, 3 turns per expert, a 25 s run and a 12 s per-call limit. The aggregator design
re-sets these values. Open: `docs/TASKLIST.md`, D5.

### 3.5 Knowledge banks
- Sources: open-access research summaries and hand-written notes.
- Each note: frontmatter with `source_id`, `title`, `url`, `licence`, `retrieved`, and a body of 150 to 400 words in
  our own words.
- Index: Vectorize `illunis-knowledge`, metadata `{expert, source_id, title, url, licence}`. Ingest with
  `server/scripts/ingest-knowledge.mjs`, which needs a Cloudflare token.

---

## 4. Analysis (21 days)

- Plain code computes everything: baseline, rolling mean, standard deviation, trend, effect size and quality flags.
  Method and thresholds: `docs/RESEARCH.md` section 2.
- The model never computes numbers. It receives structured findings only and may phrase them. The phrasing check
  rejects any number that is not in the input.
- Findings are stored as hypotheses with a confidence (0.2 if any quality flag) and an expiry of 14 days.
- Wording: "observation", "tentative", "in these check-ins". Never "conclusion", "diagnosis", condition names,
  "burnout" or causal claims.
- Health Connect supplies sleep, steps and heart rate on Android. Missing data stays missing.

---

## 5. Voice and text

### 5.1 Speech in
- Wake word: the user's own 2 to 4 word phrase. Engine: sherpa-onnx keyword spotting (a release blocker is the
  licence of the KWS model package).
- Speech to text: Whisper tiny.en now. Muse Voice Transcribe and Parakeet-TDT-0.6b-v3 are candidates. The engine
  sits behind an interface.
- Hallucination guard: the voice-activity threshold is tied to the endpoint threshold, not an absolute -55 dBFS.
- Speech ends are detected against the session's room floor.

### 5.2 Speech out
- Kokoro via sherpa-onnx, behind a `TtsEngine` interface. Default voice `af_heart`. Speech is always on.
- Barge-in: user speech stops playback and cancels generation.
- Streaming: the Worker sends sentences over SSE. The phone speaks each sentence as it arrives. A sentence is
  released only after the next one passes the safety gate.

### 5.3 Captions
- Centred on the screen. Dismissable by tap. Fog and mist effects are an optional setting, default on.
- Font: Cormorant Garamond Light or Regular. Dissolve via a small shader during the fade only.
- Reduced motion or shaders off: plain opacity fade.
- Captions keep a `Semantics` label.

### 5.4 Spoken approval
- An assistant action is read back exactly. The user must say "yes", "do it" or "go ahead".
- Any other answer, or 8 seconds of silence, cancels. Nothing is confirmed automatically.
- An expired request says so and sends nothing.

### 5.5 Text fallback
- A typed chat with the same brain, council and gates.
- Used when voice cannot be used: microphone denied, wake word or transcription failing, a noisy room, or the user's choice.
- Resolved: text chat is the fallback UI (`PLAN.md`, decision 2026-10-26b). Voice follows after the hackathons.

---

## 6. Data protection

`DATA_MODE` controls where health data may go. It is enforced on the council, reply, memory and text paths.

| Mode | Allows | Use |
|---|---|---|
| `owner_real` (default when unset) | Providers that do not train on prompts: Meta standard tier, Nebius with the training opt-out, the owner's local Hermes. Refuses contributor models and free test tiers. | Any real data from anyone other than the owner. |
| `owner_any` | Every provider, including contributor models | The owner's own data, for testing. Owner consent recorded 2026-10-25. |
| `synthetic` | Test providers allowed | Generated demo history only. |

Rules everywhere:
- No real user data in tests. Fixtures are synthetic.
- No keys or tokens in the repository. Keys are Worker secrets (`npx wrangler secret put <NAME>`).
- Logs carry IDs and fixed error codes, never payloads, keys or prompts.
- Every health output carries the not-medical-advice line and a clinician path.
- Crisis language gets a fixed referral before any model is called.
- Health text reaches a third-party model only through a provider allowed by the mode.
- Before any real data goes to a provider: check its training terms, retention and DPA (`docs/RESEARCH.md`).

---

## 7. Health scope

The app stays general wellbeing. The server refuses or redirects:
- diagnosis, treatment, medication, dose and disease claims;
- numeric targets for conditions (blood pressure, glucose, HbA1c, heart-rate thresholds);
- symptoms, injury, pregnancy and eating-disorder topics (with general resources and a calorie floor).

Keyword checks are brittle. The reviewer decides how far to rely on them (`docs/TASKLIST.md`, D9).

---

## 8. Build and verification

- Server: `cd server && npm test` (`node --test`). Run `node scripts/check-deploy.mjs` before a deploy.
- Client: `cd client && flutter analyze && flutter test`. The Flutter SDK is at `~/development/flutter`. If it is missing,
  record "not compiled" in the task list rather than skipping silently.
- Hermes tools: `uv run --no-project --with pytest pytest integrations/hermes/tools -q`.
- Done means: the tests reproduce the behaviour. Reading the code is not a test.
- Device checks run on the test phone with the owner's data and are recorded in `docs/TASKLIST.md`.
