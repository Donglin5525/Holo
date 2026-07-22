const DEFAULT_CONFIG = {
  auth: {
    enforceAppAttest: process.env.HOLO_ENFORCE_APP_ATTEST === "true",
    appAttestTeamId: process.env.HOLO_APP_ATTEST_TEAM_ID ?? "",
    appAttestBundleId: process.env.HOLO_APP_ATTEST_BUNDLE_ID ?? "com.tangyuxuan.holo-app",
    appAttestEnvironment: process.env.HOLO_APP_ATTEST_ENVIRONMENT ?? "production",
    appAttestRootCertificatePath: process.env.HOLO_APP_ATTEST_ROOT_CERTIFICATE_PATH ?? "",
    appAttestChallengeTtlSeconds: Number(process.env.HOLO_APP_ATTEST_CHALLENGE_TTL_SECONDS ?? 300),
    appleClientIds: csv(
      process.env.HOLO_APPLE_CLIENT_IDS ?? "com.tangyuxuan.holo-app,com.holo.Holo",
    ),
    internalDiagnosticsAppleSubs: csv(process.env.HOLO_INTERNAL_DIAGNOSTICS_APPLE_SUBS ?? ""),
    sessionSecret: process.env.HOLO_SESSION_SECRET ?? "",
    sessionTtlSeconds: Number(process.env.HOLO_SESSION_TTL_SECONDS ?? 3600),
    sessionIssuer: process.env.HOLO_SESSION_ISSUER ?? "holo-ai-gateway",
    sessionAudience: process.env.HOLO_SESSION_AUDIENCE ?? "holo-ios",
  },
  limits: {
    chatMaxBodyBytes: Number(process.env.HOLO_CHAT_MAX_BODY_BYTES ?? 256 * 1024),
    chatMaxMessages: Number(process.env.HOLO_CHAT_MAX_MESSAGES ?? 100),
    chatMaxMessageChars: Number(process.env.HOLO_CHAT_MAX_MESSAGE_CHARS ?? 64 * 1024),
    chatMaxTotalChars: Number(process.env.HOLO_CHAT_MAX_TOTAL_CHARS ?? 200 * 1024),
    deviceIdMaxChars: Number(process.env.HOLO_DEVICE_ID_MAX_CHARS ?? 128),
    chatRequestsPerMinute: Number(process.env.HOLO_CHAT_REQUESTS_PER_MINUTE ?? 20),
    chatRequestsPerDay: Number(process.env.HOLO_CHAT_REQUESTS_PER_DAY ?? 50),
    asrRequestsPerMinute: Number(process.env.HOLO_ASR_REQUESTS_PER_MINUTE ?? 10),
    asrRequestsPerDay: Number(process.env.HOLO_ASR_REQUESTS_PER_DAY ?? 20),
    asrMaxBytes: Number(process.env.HOLO_ASR_MAX_BYTES ?? 10 * 1024 * 1024),
    asrAllowedMimeTypes: csv(
      process.env.HOLO_ASR_ALLOWED_MIME_TYPES
        ?? "audio/wav,audio/x-wav,audio/m4a,audio/mp4,audio/mpeg,audio/aac,audio/webm,audio/ogg,application/octet-stream",
    ),
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
      maxTokens: Number(process.env.HOLO_INSIGHT_MAX_TOKENS ?? 4096),
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
    memory_domain_extraction: {
      provider: process.env.HOLO_MEMORY_DOMAIN_EXTRACTION_PROVIDER
        ?? process.env.HOLO_MEMORY_OBSERVER_PROVIDER
        ?? process.env.HOLO_CHAT_PROVIDER
        ?? "mock",
      model: process.env.HOLO_MEMORY_DOMAIN_EXTRACTION_MODEL
        ?? process.env.HOLO_MEMORY_OBSERVER_MODEL
        ?? process.env.HOLO_CHAT_MODEL
        ?? "holo-mock",
      temperature: Number(process.env.HOLO_MEMORY_DOMAIN_EXTRACTION_TEMPERATURE ?? 0.1),
      maxTokens: Number(process.env.HOLO_MEMORY_DOMAIN_EXTRACTION_MAX_TOKENS ?? 4096),
      requestLimits: {
        perMinute: Number(process.env.HOLO_MEMORY_DOMAIN_EXTRACTION_REQUESTS_PER_MINUTE ?? 6),
        perDay: Number(process.env.HOLO_MEMORY_DOMAIN_EXTRACTION_REQUESTS_PER_DAY ?? 60),
      },
    },
    memory_cross_domain_fusion: {
      provider: process.env.HOLO_MEMORY_CROSS_DOMAIN_FUSION_PROVIDER
        ?? process.env.HOLO_MEMORY_DOMAIN_EXTRACTION_PROVIDER
        ?? process.env.HOLO_CHAT_PROVIDER
        ?? "mock",
      model: process.env.HOLO_MEMORY_CROSS_DOMAIN_FUSION_MODEL
        ?? process.env.HOLO_MEMORY_DOMAIN_EXTRACTION_MODEL
        ?? process.env.HOLO_CHAT_MODEL
        ?? "holo-mock",
      temperature: Number(process.env.HOLO_MEMORY_CROSS_DOMAIN_FUSION_TEMPERATURE ?? 0.1),
      maxTokens: Number(process.env.HOLO_MEMORY_CROSS_DOMAIN_FUSION_MAX_TOKENS ?? 4096),
      requestLimits: {
        perMinute: Number(process.env.HOLO_MEMORY_CROSS_DOMAIN_FUSION_REQUESTS_PER_MINUTE ?? 2),
        perDay: Number(process.env.HOLO_MEMORY_CROSS_DOMAIN_FUSION_REQUESTS_PER_DAY ?? 10),
      },
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
    loginMaxAttempts: Number(process.env.HOLO_ADMIN_LOGIN_MAX_ATTEMPTS ?? 5),
    loginWindowSeconds: Number(process.env.HOLO_ADMIN_LOGIN_WINDOW_SECONDS ?? 900),
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
    appAttestVerifier: overrides.appAttestVerifier,
    appAttestStore: overrides.appAttestStore,
    adminLogStore: overrides.adminLogStore,
    usageStore: overrides.usageStore,
    providerOverrides: overrides.providerOverrides,
    agentStepIdempotencyStore: overrides.agentStepIdempotencyStore,
    agentStepIdempotencyEncryptionKey:
      overrides.agentStepIdempotencyEncryptionKey
        ?? process.env.HOLO_AGENT_STEP_IDEMPOTENCY_ENCRYPTION_KEY
        ?? "",
    agentStepIdempotencyPreviousEncryptionKeys:
      overrides.agentStepIdempotencyPreviousEncryptionKeys
        ?? process.env.HOLO_AGENT_STEP_IDEMPOTENCY_PREVIOUS_ENCRYPTION_KEYS
        ?? "",
    runtimeEnvironment: overrides.runtimeEnvironment ?? process.env.NODE_ENV ?? "development",
    agentStepIdempotencyTtlSeconds: Number(
      overrides.agentStepIdempotencyTtlSeconds
        ?? process.env.HOLO_AGENT_STEP_IDEMPOTENCY_TTL_SECONDS
        ?? 86_400,
    ),
    agentStepIdempotencyCleanupIntervalMs: Number(
      overrides.agentStepIdempotencyCleanupIntervalMs
        ?? process.env.HOLO_AGENT_STEP_IDEMPOTENCY_CLEANUP_INTERVAL_MS
        ?? 3_600_000,
    ),
    database: overrides.database ?? null,
    contentCaptureEnabled:
      overrides.contentCaptureEnabled
        ?? process.env.HOLO_LOG_CAPTURE_CONTENT === "true",
    logRetentionDays: Number(overrides.logRetentionDays ?? process.env.HOLO_LOG_RETENTION_DAYS ?? 7),
    dbPath: overrides.dbPath ?? process.env.HOLO_DB_PATH ?? "/data/holo-backend.db",
  };
}

export function validateRuntimeConfig(config) {
  const positiveLimits = [
    "chatMaxBodyBytes", "chatMaxMessages", "chatMaxMessageChars", "chatMaxTotalChars",
    "deviceIdMaxChars", "chatRequestsPerMinute", "chatRequestsPerDay",
    "asrRequestsPerMinute", "asrRequestsPerDay", "asrMaxBytes",
  ];
  for (const key of positiveLimits) {
    if (!Number.isFinite(config.limits[key]) || config.limits[key] <= 0) {
      throw new Error(`配置 ${key} 必须为正数`);
    }
  }
  if (!Array.isArray(config.limits.asrAllowedMimeTypes) || config.limits.asrAllowedMimeTypes.length === 0) {
    throw new Error("配置 asrAllowedMimeTypes 不能为空");
  }

  if (config.runtimeEnvironment !== "production") return;

  const referencedProviders = new Set(Object.values(config.routes).map((route) => route.provider));
  if (referencedProviders.has("mock")) {
    throw new Error("生产环境禁止使用 mock AI provider");
  }
  for (const name of referencedProviders) {
    const provider = config.providers[name];
    if (!provider && !(config.providerOverrides ?? []).some(([overrideName]) => overrideName === name)) {
      throw new Error(`生产 AI provider 未配置: ${name}`);
    }
    if (provider) {
      if (!provider.apiKey) throw new Error(`生产 AI provider 缺少 API Key: ${name}`);
      if (!isSecureURL(provider.baseURL, "https:")) {
        throw new Error(`生产 AI provider 必须使用 HTTPS: ${name}`);
      }
    }
  }
  if (!config.asrProvider) {
    if (config.asr.provider === "mock") throw new Error("生产环境禁止使用 mock ASR provider");
    if (config.asr.provider === "dashscope" && !config.asr.dashscopeApiKey) {
      throw new Error("生产 DashScope ASR 缺少 API Key");
    }
    if (!isSecureURL(config.asr.dashscopeWebSocketURL, "wss:")) {
      throw new Error("生产 ASR 必须使用 WSS");
    }
  }
  if (typeof config.auth.sessionSecret !== "string" || config.auth.sessionSecret.length < 32) {
    throw new Error("生产 HOLO_SESSION_SECRET 至少需要 32 个字符");
  }
  if (config.auth.enforceAppAttest) {
    if (!config.auth.appAttestTeamId || !config.auth.appAttestBundleId) {
      throw new Error("生产 App Attest 必须配置 Team ID 和 Bundle ID");
    }
    if (!["production", "development"].includes(config.auth.appAttestEnvironment)) {
      throw new Error("HOLO_APP_ATTEST_ENVIRONMENT 只能是 production 或 development");
    }
    if (!config.auth.appAttestRootCertificatePath && !config.appAttestVerifier) {
      throw new Error("生产 App Attest 必须配置可信 Apple Root CA 文件");
    }
  }
  if (config.admin.password && config.admin.sessionSecret.length < 32) {
    throw new Error("生产管理员密码登录必须配置至少 32 字符的独立 session secret");
  }
}

function isSecureURL(value, protocol) {
  try {
    return new URL(value).protocol === protocol;
  } catch {
    return false;
  }
}
