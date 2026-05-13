export function createInMemoryUsageStore(clock = () => new Date()) {
  const minuteBuckets = new Map();
  const dailyBuckets = new Map();

  return {
    consume({ deviceId, purpose, minuteLimit, dailyLimit }) {
      const now = clock();
      const minuteKey = `${deviceId}:${purpose}:${formatMinute(now)}`;
      const dayKey = `${deviceId}:${purpose}:${formatDay(now)}`;

      const minuteCount = (minuteBuckets.get(minuteKey) ?? 0) + 1;
      const dayCount = (dailyBuckets.get(dayKey) ?? 0) + 1;

      if (minuteCount > minuteLimit || dayCount > dailyLimit) {
        return { allowed: false };
      }

      minuteBuckets.set(minuteKey, minuteCount);
      dailyBuckets.set(dayKey, dayCount);
      return { allowed: true };
    },
  };
}

function formatMinute(date) {
  return date.toISOString().slice(0, 16);
}

function formatDay(date) {
  return date.toISOString().slice(0, 10);
}
