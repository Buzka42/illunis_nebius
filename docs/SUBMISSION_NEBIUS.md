# Nebius submission: form text (draft, 2026-10-29)

## Inspiration

I am a personal trainer. The complaint I hear most from clients who use AI to track calories is that the estimates are
inaccurate. A model that gives a number with no source cannot be checked, so a client cannot trust it. I wanted an
assistant that cites where its advice comes from, and that checks any calorie figure against the web before it is kept.

## What it does

The core is an expert council. A brain model on Nebius Token Factory reads a question and decides which experts to
consult: diet, training, breath and stress, or sleep and lifestyle. Each expert answers only from its own knowledge bank
(NHS, MedlinePlus, NCCIH and NIMH content). A point is kept only if it cites a source that the expert was given.

Tavily verification runs in two places:
- **Experts:** when a bank has too little on a question, the expert searches the web, and the results become cited sources.
- **Food:** when a user logs a meal and states its calories, Tavily checks the figure against a web source. A mismatch is
  never changed silently. The user sees both numbers and chooses one.

Supporting parts: a typed chat (voice is off in this build), food and activity logs, and a breathwork guide.

## How we built it

- **Brain and experts on Nebius Token Factory:** Nemotron 3 Super 120B for the council, Nemotron 3 Ultra 550B for chat
  replies (plain prose), and Qwen3-Embedding-8B (1024 dimensions) for retrieval over the knowledge banks.
- **Tavily** for expert web checks and food verification.
- **Server:** a Cloudflare Worker, with Vectorize for the knowledge index and Durable Objects for per-device quotas.
- **Phone app:** Flutter, with a GPU shader for the sky and a glass chat composer.
- **Safety in code:** crisis phrases get a fixed referral before any model call. The model marks health advice that could
  cause harm, and only those answers get the clinician line. A rule check catches diagnosis and prescription claims.

## Challenges we ran into

- The first food check compared the wrong number. A per-cup figure was scaled to 200 g and gave 410 kcal for rice that is
  about 260 kcal. The check now uses only figures stated per 100 g or per 100 ml, and it compares the median across sources.
- The chat model wrote its planning into answers. We turned its reasoning off on the answer path, and a rule in the base
  prompt keeps replies to plain prose.
- The medical experts are off in this build, so medical questions get no consulted source. The app says so instead of
  citing sources it does not have.

## Accomplishments that we're proud of

- Every expert point in the answer traces to a named source, and points without one are dropped.
- The food check caught and corrected a real error in our own pipeline during testing, and the mismatch path asks the
  user to choose rather than overwriting.
- A council of narrow experts runs end to end on Nebius, with Tavily verification, against a synthetic deployment.

## What we learned

A council of narrow experts, each with its own sources, is easier to check than one large model answering alone. Keeping
each model's job narrow (extract, cite, answer, verify) made every part testable. Verification changed our own output: it
found a unit error that the model's text would have hidden.

## What's next for Illunis Verify - Nemotron Nutrition Truth

Illunis Verify turns the food check into a nutrition truth layer for clients who track with AI. Next:
- Calorie estimates for foods logged without a stated figure, each marked as an estimate with its source.
- Macros (protein, carbohydrate, fat), checked the same way as calories.
- A measured accuracy test: a set of common foods with reference values, reporting how often the estimate lands within
  the tolerance, so the accuracy claim is measured rather than asserted.
- A trainer view, so a coach can review a client's logged entries and mismatches.
