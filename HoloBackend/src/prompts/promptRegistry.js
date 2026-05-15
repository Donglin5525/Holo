import defaultPrompts from "./defaultPrompts.json" with { type: "json" };
import { existsSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const PROMPT_VERSIONS = {
  intent_recognition: 5,
  memory_insight_generation: 4,
  annual_review: 1,
};
const PROMPT_TYPES = Object.keys(defaultPrompts);
const MANAGED_PROMPTS_PATH = join(dirname(fileURLToPath(import.meta.url)), "managedPrompts.json");

let managedPrompts = loadManagedPrompts();

export function listPrompts() {
  return PROMPT_TYPES.map((type) => ({
    type,
    version: getPromptVersion(type),
    source: managedPrompts[type] ? "managed" : "default",
    updatedAt: managedPrompts[type]?.updatedAt ?? null,
    contentLength: getPrompt(type)?.content.length ?? 0,
  }));
}

export function getPrompt(type) {
  if (!PROMPT_TYPES.includes(type)) {
    return null;
  }

  const managedPrompt = managedPrompts[type];
  const content = managedPrompt?.content ?? defaultPrompts[type];
  if (!content) {
    return null;
  }

  return {
    type,
    version: getPromptVersion(type),
    source: managedPrompt ? "managed" : "default",
    updatedAt: managedPrompt?.updatedAt ?? null,
    content,
  };
}

export function updatePrompt(type, content) {
  if (!PROMPT_TYPES.includes(type)) {
    return null;
  }

  const previous = getPrompt(type);
  const version = (previous?.version ?? PROMPT_VERSIONS[type] ?? 1) + 1;
  const updatedAt = new Date().toISOString();
  managedPrompts = {
    ...managedPrompts,
    [type]: {
      type,
      version,
      content,
      updatedAt,
    },
  };
  saveManagedPrompts();
  return getPrompt(type);
}

export function resetPrompt(type) {
  if (!PROMPT_TYPES.includes(type)) {
    return null;
  }

  const { [type]: _removed, ...rest } = managedPrompts;
  managedPrompts = rest;
  saveManagedPrompts();
  return getPrompt(type);
}

function getPromptVersion(type) {
  return managedPrompts[type]?.version ?? PROMPT_VERSIONS[type] ?? 1;
}

function loadManagedPrompts() {
  if (!existsSync(MANAGED_PROMPTS_PATH)) {
    return {};
  }

  try {
    return JSON.parse(readFileSync(MANAGED_PROMPTS_PATH, "utf8"));
  } catch {
    return {};
  }
}

function saveManagedPrompts() {
  if (Object.keys(managedPrompts).length === 0) {
    if (existsSync(MANAGED_PROMPTS_PATH)) {
      unlinkSync(MANAGED_PROMPTS_PATH);
    }
    return;
  }

  writeFileSync(MANAGED_PROMPTS_PATH, `${JSON.stringify(managedPrompts, null, 2)}\n`);
}
