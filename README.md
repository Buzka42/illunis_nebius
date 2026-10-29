# Illunis Verify (Nebius build)

An expert council for wellbeing questions, where every point cites a named source, and every calorie figure a user
states is checked on the web before it is kept.

Built for the Nebius submission. Brain and experts run on Nebius Token Factory. Verification runs on Tavily.

## What is here

- `server/`: a Cloudflare Worker (TypeScript-free JavaScript, Node test runner).
  - `src/council/`: the council relay (brain) and expert registry.
  - `src/knowledge/`: retrieval over Vectorize, embeddings on Nebius (Qwen3-Embedding-8B, 1024 dimensions).
  - `src/providers/tavily.js`, `src/council/web.js`: Tavily web search (expert checks, food checks).
  - `src/logs/`: food and activity parsing, with the per-100 g calorie check and the user's choice.
  - `src/safety.js`, `src/reply.js`: crisis referral, output rules, one repair pass, the clinician line.
- `client/`: the Flutter phone app (chat, council answers with sources, food choice, logs, breathwork, sky).
- `content/`: personalities, skills, breathwork techniques and their schemas, with `content/validate.mjs`.
- `knowledge/`: the expert knowledge banks (NHS, MedlinePlus, NCCIH, NIMH notes, with licence and source per file).
- `tools/synthetic/`: a generator for synthetic demo history. All demos use synthetic data.

## Run the tests

```
cd server && npm install && npm test          # 363 tests
node ../content/validate.mjs                  # 30 content files
cd ../client && flutter test                  # widget and unit tests
```

## Deploy (summary)

Secrets (`wrangler secret put`): `NEBIUS_API_KEY`, `TAVILY_API_KEY`, `DEVICE_TOKEN_SECRET`.
Variables: `REPLY_PROVIDER=nebius`, `REPLY_LLM_MODEL`, `COUNCIL_NEBIUS_MODEL`, `KNOWLEDGE_EMBED_PROVIDER=nebius`,
`KNOWLEDGE_EMBED_MODEL=Qwen/Qwen3-Embedding-8B`, `DATA_MODE=synthetic`. Leave `META_API_KEY` unset.
Full notes in `server/docs/SETUP.md`. Live checks: `node server/scripts/check-deploy.mjs --smoke <base_url>`.

## Scope and honesty

- Medical experts are off in this build. Medical questions are answered without a consulted source, and say so.
- Voice is off in this build. Replies are typed.
- Meta and the Hermes assistant bridge are present in code but inert without their configuration.
- Food calories are checked only when the user states a figure. Foods logged without one are saved without a calorie count.
- Tested live on a synthetic deployment; see `docs/NEBIUS_TEST_RESULTS.md`.

## Licences

Knowledge notes carry their own licence per file (NHS content under the Open Government Licence, MedlinePlus public domain).
Moon imagery: NASA SVS, see `client/assets/` attribution. Line-art style for diagrams is inspired by Krbn (MIT).
