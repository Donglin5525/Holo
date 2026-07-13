const DEFAULT_CONFIG = {
  auth: {
    enforceAppAttest: process.env.HOLO_ENFORCE_APP_ATTEST === "true",
    appleClientIds: csv(process.env.HOLO_APPLE_CLIENT_IDS ?? "com.holo.Holo"),
    internalDiagnosticsAppleSubs: csv(process.env.HOLO_INTERNAL_DIAGNOSTICS_APPLE_SUBS ?? ""),
    sessionSecret: process.env.HOLO_SESSION_SECRET ?? "",
    sessionTtlSeconds: Number(process.env.HOLO_SESSION_TTL_SECONDS ?? 3600),
    sessionIssuer: process.env.HOLO_SESSION_ISSUER ?? "holo-ai-gateway",
    sessionAudience: process.env.HOLO_SESSION_AUDIENCE ?? "holo-ios",
  },
  limits: {
    chatRequestsPerMinute: Number(process.env.HOLO_CHAT_REQUESTS_PER_MINUTE ?? 20),
    chatRequestsPerDay: Number(process.env.HOLO_CHAT_REQUESTS_PER_DAY ?? 50),
    asrRequestsPerMinute: Number(process.env.HOLO_ASR_REQUESTS_PER_MINUTE ?? 10),
    asrRequestsPerDay: Number(process.env.HOLO_ASR_REQUESTS_PER_DAY ?? 20),
    asrMaxBytes: Number(process.env.HOLO_ASR_MAX_BYTES ?? 10 * 1024 * 1024),
  },
  routes: {
    chat: {
      provider: process.env.HOLO_CHAT_PROVIDER ?? "mock",
      model: process.env.HOLO_CHAT_MODEL ?? "holo-mock",
      temperature: Number(process.env.HOLO_CHAT_TEMPERATURE ?? 0.2),
      maxTokens: Number(process.env.HOLO_CHAT_MAX_TOKENS ?? 1024),
    },
    analysis: {
      provider: process.env.HOLO_ANALYSIS_PROVIDER ?? process.env.HOLO_CHAT_PROVIDER ?? "mock",
      model: process.env.HOLO_ANALYSIS_MODEL ?? process.env.HOLO_CHAT_MODEL ?? "holo-mock",
      temperature: Number(process.env.HOLO_ANALYSIS_TEMPERATURE ?? 0.2),
      maxTokens: Number(process.env.HOLO_ANALYSIS_MAX_TOKENS ?? 4096),
    },
    intent: {
      provider: process.env.HOLO_INTENT_PROVIDER ?? process.env.HOLO_CHAT_PROVIDER ?? "mock",
      model: process.env.HOLO_INTENT_MODEL ?? process.env.HOLO_CHAT_MODEL ?? "holo-mock",
      temperature: Number(process.env.HOLO_INTENT_TEMPERATURE ?? 0),
      maxTokens: Number(process.env.HOLO_INTENT_MAX_TOKENS ?? 4096),
    },
    flexible_query_planner: {
      provider: process.env.HOLO_FLEXIBLE_QUERY_PLANNER_PROVIDER
        ?? process.env.HOLO_INTENT_PROVIDER
        ?? process.env.HOLO_CHAT_PROVIDER
        ?? "mock",
      model: process.env.HOLO_FLEXIBLE_QUERY_PLANNER_MODEL
        ?? process.env.HOLO_INTENT_MODEL
        ?? process.env.HOLO_CHAT_MODEL
        ?? "holo-mock",
      temperature: Number(process.env.HOLO_FLEXIBLE_QUERY_PLANNER_TEMPERATURE ?? 0),
      maxTokens: Number(process.env.HOLO_FLEXIBLE_QUERY_PLANNER_MAX_TOKENS ?? 4096),
    },
    insight: {
      provider: process.env.HOLO_INSIGHT_PROVIDER ?? process.env.HOLO_CHAT_PROVIDER ?? "mock",
      model: process.env.HOLO_INSIGHT_MODEL ?? process.env.HOLO_CHAT_MODEL ?? "holo-mock",
      temperature: Number(process.env.HOLO_INSIGHT_TEMPERATURE ?? 0.3),
      maxTokens: Number(process.env.HOLO_INSIGHT_MAX_TOKENS ?? 2048),
    },
    health_insight_generation: {
      provider: process.env.HOLO_HEALTH_INSIGHT_PROVIDER ?? process.env.HOLO_INSIGHT_PROVIDER ?? process.env.HOLO_CHAT_PROVIDER ?? "mock",
      model: process.env.HOLO_HEALTH_INSIGHT_MODEL ?? process.env.HOLO_INSIGHT_MODEL ?? process.env.HOLO_CHAT_MODEL ?? "holo-mock",
      temperature: Number(process.env.HOLO_HEALTH_INSIGHT_TEMPERATURE ?? 0.35),
      maxTokens: Number(process.env.HOLO_HEALTH_INSIGHT_MAX_TOKENS ?? 1600),
    },
    thought_voice_summary: {
      provider: process.env.HOLO_THOUGHT_VOICE_SUMMARY_PROVIDER
        ?? process.env.HOLO_CHAT_PROVIDER
        ?? "mock",
      model: process.env.HOLO_THOUGHT_VOICE_SUMMARY_MODEL
        ?? process.env.HOLO_CHAT_MODEL
        ?? "holo-mock",
      temperature: Number(process.env.HOLO_THOUGHT_VOICE_SUMMARY_TEMPERATURE ?? 0.3),
      maxTokens: Number(process.env.HOLO_THOUGHT_VOICE_SUMMARY_MAX_TOKENS ?? 1024),
    },
    memory_observer: {
      provider: process.env.HOLO_MEMORY_OBSERVER_PROVIDER
        ?? process.env.HOLO_CHAT_PROVIDER
        ?? "mock",
      model: process.env.HOLO_MEMORY_OBSERVER_MODEL
        ?? process.env.HOLO_CHAT_MODEL
        ?? "holo-mock",
      temperature: Number(process.env.HOLO_MEMORY_OBSERVER_TEMPERATURE ?? 0.1),
      maxTokens: Number(process.env.HOLO_MEMORY_OBSERVER_MAX_TOKENS ?? 2048),
    },
    finance_action_parser: {
      provider: process.env.HOLO_FINANCE_ACTION_PARSER_PROVIDER ?? process.env.HOLO_INTENT_PROVIDER ?? process.env.HOLO_CHAT_PROVIDER ?? "mock",
      model: process.env.HOLO_FINANCE_ACTION_PARSER_MODEL ?? process.env.HOLO_INTENT_MODEL ?? process.env.HOLO_CHAT_MODEL ?? "holo-mock",
      temperature: Number(process.env.HOLO_FINANCE_ACTION_PARSER_TEMPERATURE ?? 0),
      maxTokens: Number(process.env.HOLO_FINANCE_ACTION_PARSER_MAX_TOKENS ?? 512),
    },
    task_action_parser: {
      provider: process.env.HOLO_TASK_ACTION_PARSER_PROVIDER ?? process.env.HOLO_INTENT_PROVIDER ?? process.env.HOLO_CHAT_PROVIDER ?? "mock",
      model: process.env.HOLO_TASK_ACTION_PARSER_MODEL ?? process.env.HOLO_INTENT_MODEL ?? process.env.HOLO_CHAT_MODEL ?? "holo-mock",
      temperature: Number(process.env.HOLO_TASK_ACTION_PARSER_TEMPERATURE ?? 0),
      maxTokens: Number(process.env.HOLO_TASK_ACTION_PARSER_MAX_TOKENS ?? 512),
    },
    thought_organization: {
      provider: process.env.HOLO_THOUGHT_ORG_PROVIDER ?? process.env.HOLO_CHAT_PROVIDER ?? "mock",
      model: process.env.HOLO_THOUGHT_ORG_MODEL ?? process.env.HOLO_CHAT_MODEL ?? "holo-mock",
      temperature: Number(process.env.HOLO_THOUGHT_ORG_TEMPERATURE ?? 0.2),
      maxTokens: Number(process.env.HOLO_THOUGHT_ORG_MAX_TOKENS ?? 512),
    },
    thought_tag_convergence: {
      provider: process.env.HOLO_THOUGHT_CONVERGENCE_PROVIDER ?? process.env.HOLO_CHAT_PROVIDER ?? "mock",
      model: process.env.HOLO_THOUGHT_CONVERGENCE_MODEL ?? process.env.HOLO_CHAT_MODEL ?? "holo-mock",
      temperature: Number(process.env.HOLO_THOUGHT_CONVERGENCE_TEMPERATURE ?? 0.3),
      maxTokens: Number(process.env.HOLO_THOUGHT_CONVERGENCE_MAX_TOKENS ?? 1024),
    },
    category_pattern_induction: {
      provider: process.env.HOLO_CATEGORY_INDUCTION_PROVIDER ?? process.env.HOLO_CHAT_PROVIDER ?? "mock",
      model: process.env.HOLO_CATEGORY_INDUCTION_MODEL ?? process.env.HOLO_CHAT_MODEL ?? "holo-mock",
      temperature: Number(process.env.HOLO_CATEGORY_INDUCTION_TEMPERATURE ?? 0.2),
      maxTokens: Number(process.env.HOLO_CATEGORY_INDUCTION_MAX_TOKENS ?? 1024),
    },
    agent_loop: {
      provider: process.env.HOLO_AGENT_LOOP_PROVIDER ?? process.env.HOLO_CHAT_PROVIDER ?? "mock",
      model: process.env.HOLO_AGENT_LOOP_MODEL ?? process.env.HOLO_CHAT_MODEL ?? "holo-mock",
      temperature: Number(process.env.HOLO_AGENT_LOOP_TEMPERATURE ?? 0.1),
      maxTokens: Number(process.env.HOLO_AGENT_LOOP_MAX_TOKENS ?? 8192),
      requestLimits: {
        perMinute: Number(process.env.HOLO_AGENT_LOOP_REQUESTS_PER_MINUTE ?? 60),
        perDay: Number(process.env.HOLO_AGENT_LOOP_REQUESTS_PER_DAY ?? 500),
      },
    },
  },
  providers: {
    deepseek: {
      type: "openai-compatible",
      baseURL: process.env.DEEPSEEK_BASE_URL ?? "https://api.deepseek.com",
      apiKey: process.env.DEEPSEEK_API_KEY,
    },
    qwen: {
      type: "openai-compatible",
      baseURL: process.env.QWEN_BASE_URL ?? "https://dashscope.aliyuncs.com/compatible-mode/v1",
      apiKey: process.env.QWEN_API_KEY,
    },
    moonshot: {
      type: "openai-compatible",
      baseURL: process.env.MOONSHOT_BASE_URL ?? "https://api.moonshot.cn/v1",
      apiKey: process.env.MOONSHOT_API_KEY,
    },
    zhipu: {
      type: "openai-compatible",
      baseURL: process.env.ZHIPU_BASE_URL ?? "https://open.bigmodel.cn/api/paas/v4",
      apiKey: process.env.ZHIPU_API_KEY,
    },
  },
  asr: {
    provider: process.env.HOLO_ASR_PROVIDER ?? "mock",
    dashscopeApiKey: process.env.DASHSCOPE_API_KEY,
    dashscopeWebSocketURL: process.env.DASHSCOPE_ASR_WEBSOCKET_URL ?? "wss://dashscope.aliyuncs.com/api-ws/v1/realtime",
    model: process.env.DASHSCOPE_ASR_MODEL ?? "qwen3-asr-flash-realtime",
    language: process.env.DASHSCOPE_ASR_LANGUAGE ?? "zh",
    sampleRate: Number(process.env.DASHSCOPE_ASR_SAMPLE_RATE ?? 16_000),
  },
  admin: {
    token: process.env.HOLO_ADMIN_TOKEN ?? "",
    username: process.env.HOLO_ADMIN_USERNAME ?? "admin",
    password: process.env.HOLO_ADMIN_PASSWORD ?? "",
    sessionSecret: process.env.HOLO_ADMIN_SESSION_SECRET ?? "",
    logMaxEntries: Number(process.env.HOLO_ADMIN_LOG_MAX_ENTRIES ?? 200),
    logDetailMaxChars: Number(process.env.HOLO_ADMIN_LOG_DETAIL_MAX_CHARS ?? 20_000),
  },
  aiCallLogs: {
    enabled: process.env.HOLO_AI_CALL_LOGS_ENABLED !== "false",
  },
};

function csv(value) {
  return [...new Set(String(value).split(",").map((item) => item.trim()).filter(Boolean))];
}

export function loadConfig(overrides = {}) {
  return {
    auth: {
      ...DEFAULT_CONFIG.auth,
      ...overrides.auth,
    },
    limits: {
      ...DEFAULT_CONFIG.limits,
      ...overrides.limits,
    },
    routes: {
      ...DEFAULT_CONFIG.routes,
      ...overrides.routes,
    },
    providers: {
      ...DEFAULT_CONFIG.providers,
      ...overrides.providers,
    },
    asr: {
      ...DEFAULT_CONFIG.asr,
      ...overrides.asr,
    },
    admin: {
      ...DEFAULT_CONFIG.admin,
      ...overrides.admin,
    },
    aiCallLogs: {
      ...DEFAULT_CONFIG.aiCallLogs,
      ...overrides.aiCallLogs,
    },
    asrProvider: overrides.asrProvider,
    appleIdentityVerifier: overrides.appleIdentityVerifier,
    holoSessionService: overrides.holoSessionService,
    adminLogStore: overrides.adminLogStore,
    usageStore: overrides.usageStore,
    database: overrides.database ?? null,
    contentCaptureEnabled: process.env.HOLO_LOG_CAPTURE_CONTENT === "true",
    logRetentionDays: Number(process.env.HOLO_LOG_RETENTION_DAYS ?? 30),
    dbPath: process.env.HOLO_DB_PATH ?? "/data/holo-backend.db",
  };
}
