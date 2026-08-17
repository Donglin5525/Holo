export const QUOTA_TYPES = Object.freeze({
  chat: "chat",
  deepAnalysis: "deepAnalysis",
  naturalLanguageFinance: "naturalLanguageFinance",
  naturalLanguageTask: "naturalLanguageTask",
  asr: "asr",
  memoryInsight: "memoryInsight",
  lifePlan: "lifePlan",
});

export const QUOTA_POLICY = Object.freeze({
  free: {
    [QUOTA_TYPES.chat]: { limit: 15, period: "day" },
    [QUOTA_TYPES.deepAnalysis]: { limit: 2, period: "day" },
    [QUOTA_TYPES.naturalLanguageFinance]: { limit: 20, period: "day" },
    [QUOTA_TYPES.naturalLanguageTask]: { limit: 20, period: "day" },
    [QUOTA_TYPES.asr]: { limit: 20, period: "day", maxSeconds: 60 },
    [QUOTA_TYPES.memoryInsight]: { limit: 1, period: "week" },
    [QUOTA_TYPES.lifePlan]: { limit: 1, period: "week" },
  },
  plus: {
    [QUOTA_TYPES.chat]: { limit: 30, period: "day" },
    [QUOTA_TYPES.deepAnalysis]: { limit: 10, period: "day" },
    [QUOTA_TYPES.naturalLanguageFinance]: { limit: 50, period: "day" },
    [QUOTA_TYPES.naturalLanguageTask]: { limit: 50, period: "day" },
    [QUOTA_TYPES.asr]: { limit: 50, period: "day", maxSeconds: 300 },
    [QUOTA_TYPES.memoryInsight]: { limit: 1, period: "day" },
    [QUOTA_TYPES.lifePlan]: { limit: 2, period: "week" },
  },
});

const DAY_FORMATTER = new Intl.DateTimeFormat("en-CA", {
  timeZone: "Asia/Shanghai",
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
});

export function getQuotaRule(tier, quotaType) {
  const normalizedTier = tier === "plus" ? "plus" : "free";
  const rule = QUOTA_POLICY[normalizedTier]?.[quotaType];
  if (!rule) throw new Error(`Unknown quota type: ${quotaType}`);
  return rule;
}

export function quotaPeriodForDate(date, period) {
  const day = shanghaiDateString(date);
  if (period === "day") {
    return { periodKey: `day:${day}`, resetAt: `${addDays(day, 1)}T00:00:00+08:00` };
  }
  if (period === "week") {
    const start = startOfShanghaiWeek(day);
    return { periodKey: `week:${start}`, resetAt: `${addDays(start, 7)}T00:00:00+08:00` };
  }
  throw new Error(`Unknown quota period: ${period}`);
}

export function shanghaiDateString(date) {
  return DAY_FORMATTER.format(date);
}

function addDays(dayString, count) {
  const [year, month, day] = dayString.split("-").map(Number);
  return new Date(Date.UTC(year, month - 1, day + count)).toISOString().slice(0, 10);
}

function startOfShanghaiWeek(dayString) {
  const [year, month, day] = dayString.split("-").map(Number);
  const utc = new Date(Date.UTC(year, month - 1, day));
  const weekday = utc.getUTCDay() || 7;
  return new Date(Date.UTC(year, month - 1, day - weekday + 1)).toISOString().slice(0, 10);
}
