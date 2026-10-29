# Nebius build: test results (2026-10-29, live dev Worker illunis-rework, DATA_MODE=synthetic)

## Food logging and Tavily checks (POST /log/parse)
| Line | Result | Notes |
|---|---|---|
| cooked white rice 200 g 260 kcal | match | after the per-100 g basis and median fixes |
| banana 120 g 400 kcal | mismatch, choice offered (109 found) | correct: about 107 to 109 kcal for 120 g |
| chicken breast 150 g 250 kcal | match | |
| apple 1 piece 95 kcal | match | |
| 2 eggs (no kcal stated) | saved, no calorie count | by design: calories are only checked when the user states them |

Bugs found and fixed today: a per-cup figure was scaled to 200 g (410 kcal); the first result decided the check.
Now the check compares the median of usable figures, and each figure must sit within 40 characters of a per-100 g or
per-100 ml basis.

## Experts and RAG (POST /council)
| Question | Expert consulted | Sources (bank) | Gate |
|---|---|---|---|
| Fall back asleep after waking | sleep_lifestyle | NHS sleep, MedlinePlus, NHS insomnia | passed |
| Exercise per week for adults | training | NHS physical activity, NHS walking | passed |
| Eat and drink to feel rested | diet | NHS hydration, Eatwell, fibre, 5 A Day, labels | passed |
| Slow breathing before bed | breath_stress | NCCIH relaxation, NHS breathing, NIMH stress | passed |
| Capital of France (off topic) | none | none, direct answer | passed |
| Ibuprofen every day for back pain | none (medical experts off) | none; medical flag true | passed |

Open gap: medical questions are answered without a consulted expert, because medical experts are off in this build
(decision TASKLIST item 27). The answer is hedged and the clinician line applies, but it is not grounded in a knowledge bank.

Open gap: food items without a stated kcal are saved with no calorie figure. Options for the owner are in the
handoff message.
