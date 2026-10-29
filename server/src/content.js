// Personality and skill content, bundled at build time by static JSON imports
// (the Worker has no fs). Source of truth: ../../content. Read-only here.
import calmGuide from "../../content/personalities/calm_guide.json" with { type: "json" };
import drillSergeant from "../../content/personalities/drill_sergeant_trainer.json" with { type: "json" };
import personalCoach from "../../content/personalities/personal_coach.json" with { type: "json" };
import productivityAdvisor from "../../content/personalities/productivity_advisor.json" with { type: "json" };
import socraticTutor from "../../content/personalities/socratic_tutor.json" with { type: "json" };
import dailyPlanner from "../../content/personalities/daily_planner.json" with { type: "json" };
import dreamCompanion from "../../content/personalities/dream_companion.json" with { type: "json" };
import reflectiveJournal from "../../content/personalities/reflective_journal_guide.json" with { type: "json" };
import habitBuilding from "../../content/skills/habit_building.json" with { type: "json" };
import meditationBasics from "../../content/skills/meditation_basics.json" with { type: "json" };
import windDown from "../../content/skills/wind_down_routine.json" with { type: "json" };
import breathwork from "../../content/skills/breathwork.json" with { type: "json" };
import motivation from "../../content/skills/motivation.json" with { type: "json" };
import weightTraining from "../../content/skills/weight_training.json" with { type: "json" };

const byId = (list) => new Map(list.map((x) => [x.id, Object.freeze(x)]));

const PERSONALITIES = byId([calmGuide, dailyPlanner, dreamCompanion, drillSergeant, personalCoach, productivityAdvisor, reflectiveJournal, socraticTutor]);
const SKILLS = byId([breathwork, habitBuilding, meditationBasics, motivation, weightTraining, windDown]);

const resolvePersonalityId = (id) => (PERSONALITIES.has(id) ? id : null);
const resolveSkillId = (id) => (SKILLS.has(id) ? id : null);

export const getPersonality = (id) => PERSONALITIES.get(resolvePersonalityId(id)) ?? null;
export const getSkill = (id) => SKILLS.get(resolveSkillId(id)) ?? null;

export const listPersonalities = () => [...PERSONALITIES.values()].map(({ id, name }) => ({ id, name }));
export const listSkills = () => [...SKILLS.values()].map(({ id, name }) => ({ id, name }));
