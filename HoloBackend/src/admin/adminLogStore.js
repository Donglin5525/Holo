import { randomUUID } from "node:crypto";

const DEFAULT_MAX_ENTRIES = 200;
const DEFAULT_MAX_DETAIL_CHARS = 20_000;

export function createAdminLogStore(options = {}) {
  const maxEntries = positiveNumber(options.maxEntries, DEFAULT_MAX_ENTRIES);
  const maxDetailChars = positiveNumber(options.maxDetailChars, DEFAULT_MAX_DETAIL_CHARS);
  const entries = [];

  function startAiCall(input) {
    const now = new Date();
    const entry = {
      id: randomUUID(),
      type: "ai.chat.completions",
      status: "pending",
      startedAt: now.toISOString(),
      finishedAt: null,
      durationMs: null,
      deviceId: input.deviceId,
      purpose: input.purpose,
      provider: input.provider,
      model: input.model,
      stream: input.stream,
      request: truncateDeep(input.request, maxDetailChars),
      response: null,
      error: null,
    };

    entries.unshift(entry);
    if (entries.length > maxEntries) {
      entries.length = maxEntries;
    }

    return entry.id;
  }

  function finishAiCall(id, result) {
    const entry = entries.find((item) => item.id === id);
    if (!entry) {
      return;
    }

    const now = new Date();
    entry.status = result.status;
    entry.finishedAt = now.toISOString();
    entry.durationMs = now.getTime() - Date.parse(entry.startedAt);
    entry.response = result.response == null ? null : truncateDeep(result.response, maxDetailChars);
    entry.error = result.error == null ? null : truncateDeep(result.error, maxDetailChars);
  }

  function list() {
    return entries.map((entry) => ({
      id: entry.id,
      type: entry.type,
      status: entry.status,
      startedAt: entry.startedAt,
      finishedAt: entry.finishedAt,
      durationMs: entry.durationMs,
      deviceId: entry.deviceId,
      purpose: entry.purpose,
      provider: entry.provider,
      model: entry.model,
      stream: entry.stream,
      errorCode: entry.error?.code ?? null,
    }));
  }

  function get(id) {
    return entries.find((entry) => entry.id === id) ?? null;
  }

  return {
    maxDetailChars,
    startAiCall,
    finishAiCall,
    list,
    get,
  };
}

export function truncateText(value, maxChars) {
  if (typeof value !== "string" || value.length <= maxChars) {
    return value;
  }

  return `${value.slice(0, maxChars)}\n...[truncated ${value.length - maxChars} chars]`;
}

function truncateDeep(value, maxChars) {
  if (typeof value === "string") {
    return truncateText(value, maxChars);
  }

  if (Array.isArray(value)) {
    return value.map((item) => truncateDeep(item, maxChars));
  }

  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([key, nestedValue]) => [key, truncateDeep(nestedValue, maxChars)]),
    );
  }

  return value;
}

function positiveNumber(value, fallback) {
  return Number.isFinite(value) && value > 0 ? value : fallback;
}
