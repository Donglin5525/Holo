const DEFAULT_CONFIG = {
  auth: {
    enforceAppAttest: process.env.HOLO_ENFORCE_APP_ATTEST === "true",
    appleClientIds: csv(
      process.env.HOLO_APPLE_CLIENT_IDS ?? "com.tangyuxuan.holo-app,com.holo.Holo",
    ),
    internalDiagnosticsAppleSubs: csv(process.env.HOLO_INTERNAL_DIAGNOSTICS_APPLE_SUBS ?? ""),
    sessionSecret: process.env.HOLO_SESSION_SECRET ?? "",
    sessionTtlSeconds: Number(process.env.HOLO_SESSION_TTL_SECONDS ?? 3600),
    sessionIssuer: process.env.HOLO_SESSION_ISSUER ?? "holo-ai-gateway",
    sessionAudience: process.env.HOLO_SESSION_AUDIENCE ?? "holo-ios",
    // Sign in with Apple 凭证撤销（App Store Guideline 5.1.1v）：账号删除时
    // 用 .p8 私钥签 client_secret，调 Apple /auth/revoke 撤销用户 identity token。
    appleRevoke: {
      teamId: process.env.APPLE_TEAM_ID ?? "6WZ5TXGPQY",
      keyId: process.env.APPLE_KEY_ID ?? "",
      clientId: process.env.APPLE_REVOKE_CLIENT_ID ?? "com.tangyuxuan.holo-app",
      privateKeyPem: process.env.APPLE_PRIVATE_KEY_PEM ?? "",
    },
  },
  limits: {
    chatRequestsPerMinute: Number(process.env.HOLO_CHAT_REQUESTS_PER_MINUTE ?? 20),
    chatRequestsPerDay: Number(process.env.HOLO_CHAT_REQUESTS_PER_DAY ?? 50),
    asrRequestsPerMinute: Number(process.env.HOLO_ASR_REQUESTS_PER_MINUTE ?? 10),
    asrRequestsPerDay: Number(process.env.HOLO_ASR_REQUESTS_PER_DAY ?? 20),
    asrMaxBytes: Number(process.env.HOLO_ASR_MAX_BYTES ?? 10 * 1024 * 1024),
    // AI 内容举报（App Store Guideline 1.2）：按设备限流，防止刷举报。
    reportRequestsPerMinute: Number(process.env.HOLO_REPORT_REQUESTS_PER_MINUTE ?? 5),
    reportRequestsPerDay: Number(process.env.HOLO_REPORT_REQUESTS_PER_DAY ?? 20),
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
      // §latency: 周期回放默认吃上游满血推理档（未传 effort 时），长输出叠加长思维链导致
      // 生成动辄 60s+；low 档可稳定输出洞察 JSON，耗时约减半。
      reasoningEffort: process.env.HOLO_INSIGHT_REASONING_EFFORT ?? "low",
    },
    weekly_plan_generation: {
      provider: process.env.HOLO_WEEKLY_PLAN_PROVIDER ?? process.env.HOLO_CHAT_PROVIDER ?? "mock",
      model: process.env.HOLO_WEEKLY_PLAN_MODEL ?? process.env.HOLO_CHAT_MODEL ?? "holo-mock",
      temperature: Number(process.env.HOLO_WEEKLY_PLAN_TEMPERATURE ?? 0.2),
      maxTokens: Number(process.env.HOLO_WEEKLY_PLAN_MAX_TOKENS ?? 4096),
      // §latency: 周计划组装输出是简单结构化 JSON（非 agent 协议），none 档实测
      // 6-8s（low 档 15-25s）且 3/3 输出有效；复杂协议（agent_loop 工具轮）不适用 none。
      reasoningEffort: process.env.HOLO_WEEKLY_PLAN_REASONING_EFFORT ?? "none",
    },
    replayDigest: {
      provider: process.env.HOLO_REPLAY_DIGEST_PROVIDER ?? process.env.HOLO_INSIGHT_PROVIDER ?? process.env.HOLO_CHAT_PROVIDER ?? "mock",
      model: process.env.HOLO_REPLAY_DIGEST_MODEL ?? process.env.HOLO_INSIGHT_MODEL ?? process.env.HOLO_CHAT_MODEL ?? "holo-mock",
      temperature: Number(process.env.HOLO_REPLAY_DIGEST_TEMPERATURE ?? 0.2),
      // §reasoning-budget: 跨周期归纳是复杂任务，推理模型（deepseek-v4-flash）会先在
      // reasoning_content 里展开大量思考，再写 content。maxTokens=1024 时思维链就吃满，
      // finish_reason=length，content 为空 → App 端报"回放摘要返回格式不正确"。
      // 提到 4096，与 insight / memory_domain_extraction 等同类复杂任务对齐。
      maxTokens: Number(process.env.HOLO_REPLAY_DIGEST_MAX_TOKENS ?? 4096),
      // §quota-isolation: 周期回放历史摘要归纳（后台迁移任务）原本与主聊天共用
      // 全局 chatRequestsPerDay=50，会挤占用户正常额度。此处给它独立配额桶。
      requestLimits: {
        perMinute: Number(process.env.HOLO_REPLAY_DIGEST_REQUESTS_PER_MINUTE ?? 10),
        perDay: Number(process.env.HOLO_REPLAY_DIGEST_REQUESTS_PER_DAY ?? 30),
      },
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
      // §model-v4-flash: 切到 v4-flash（理解力强于 deepseek-chat，能更好识别自我纠正/废话/情绪信号）。
      // 仍允许 env 覆盖，但默认不再 fallback 到 HOLO_CHAT_MODEL，避免被旧配置拖回 deepseek-chat。
      model: process.env.HOLO_THOUGHT_VOICE_SUMMARY_MODEL
        ?? "deepseek-v4-flash",
      temperature: Number(process.env.HOLO_THOUGHT_VOICE_SUMMARY_TEMPERATURE ?? 0.3),
      maxTokens: Number(process.env.HOLO_THOUGHT_VOICE_SUMMARY_MAX_TOKENS ?? 1024),
      // §reasoning-off: 语音总结是轻量文本整理任务，不需要推理模型先思考再输出。
      // 关闭思考（reasoning_effort=none）后：① 耗时从 ~1800ms 降到 ~1000ms；
      // ② reasoning_tokens 归零，1024 maxTokens 全部留给正式输出，不再有"思考吃满额度导致输出为空"的风险。
      // 与 agent_loop（用 low）同属 buildUpstreamBody 的 reasoning_effort 透传机制。
      reasoningEffort: process.env.HOLO_THOUGHT_VOICE_SUMMARY_REASONING_EFFORT ?? "none",
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
      // §reasoning-off: 与 thought_organization 同因——记忆观察/萃取是结构化信号处理，
      // 推理模型先在 reasoning_content 展开长思考导致耗时超上游 30s 网关超时
      //（生产 2026-08-04 起记忆萃取 73% 请求 "This operation was aborted"，中位 30.7s）。
      reasoningEffort: process.env.HOLO_MEMORY_OBSERVER_REASONING_EFFORT ?? "low",
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
      // §reasoning-off: 输入是客户端预筛后的结构化信号包、输出是固定 schema，
      // 不需要重推理；关思考后耗时预期从 ~30s+ 降到与 thought_organization 同量级。
      reasoningEffort: process.env.HOLO_MEMORY_DOMAIN_EXTRACTION_REASONING_EFFORT ?? "none",
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
      // 跨域融合含候选关联判断，保留 low 档思考（与 agent_loop 同级）。
      reasoningEffort: process.env.HOLO_MEMORY_CROSS_DOMAIN_FUSION_REASONING_EFFORT ?? "low",
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
      // §reasoning-off: 单条想法分类输出三字段短 JSON，无多步推理需求；输出短、分类质量由端侧低置信待确认池兜底。
      // 关闭思考（reasoning_effort=none，与 thought_voice_summary 同机制）后 reasoning_tokens 归零，
      // maxTokens 全部留给正式输出，根治"思考吃满额度导致 content 为空"（线上 ai_call_logs 实测 27% 空响应，8-05 maxTokens 调 2048 后仍复发）。
      // 若后续观察到低置信比例异常上升，再降级为 "low"。
      reasoningEffort: process.env.HOLO_THOUGHT_ORG_REASONING_EFFORT ?? "none",
      maxTokens: Number(process.env.HOLO_THOUGHT_ORG_MAX_TOKENS ?? 2048),
    },
    thought_task_extraction: {
      provider: process.env.HOLO_THOUGHT_TASK_EXTRACTION_PROVIDER ?? process.env.HOLO_CHAT_PROVIDER ?? "mock",
      model: process.env.HOLO_THOUGHT_TASK_EXTRACTION_MODEL ?? process.env.HOLO_CHAT_MODEL ?? "holo-mock",
      temperature: Number(process.env.HOLO_THOUGHT_TASK_EXTRACTION_TEMPERATURE ?? 0),
      maxTokens: Number(process.env.HOLO_THOUGHT_TASK_EXTRACTION_MAX_TOKENS ?? 1024),
    },
    thought_tag_convergence: {
      provider: process.env.HOLO_THOUGHT_CONVERGENCE_PROVIDER ?? process.env.HOLO_CHAT_PROVIDER ?? "mock",
      model: process.env.HOLO_THOUGHT_CONVERGENCE_MODEL ?? process.env.HOLO_CHAT_MODEL ?? "holo-mock",
      temperature: Number(process.env.HOLO_THOUGHT_CONVERGENCE_TEMPERATURE ?? 0.3),
      maxTokens: Number(process.env.HOLO_THOUGHT_CONVERGENCE_MAX_TOKENS ?? 2048),
    },
    category_pattern_induction: {
      provider: process.env.HOLO_CATEGORY_INDUCTION_PROVIDER ?? process.env.HOLO_CHAT_PROVIDER ?? "mock",
      model: process.env.HOLO_CATEGORY_INDUCTION_MODEL ?? process.env.HOLO_CHAT_MODEL ?? "holo-mock",
      temperature: Number(process.env.HOLO_CATEGORY_INDUCTION_TEMPERATURE ?? 0.2),
      maxTokens: Number(process.env.HOLO_CATEGORY_INDUCTION_MAX_TOKENS ?? 2048),
    },
    agent_loop: {
      provider: process.env.HOLO_AGENT_LOOP_PROVIDER ?? process.env.HOLO_CHAT_PROVIDER ?? "mock",
      model: process.env.HOLO_AGENT_LOOP_MODEL ?? process.env.HOLO_CHAT_MODEL ?? "holo-mock",
      temperature: Number(process.env.HOLO_AGENT_LOOP_TEMPERATURE ?? 0.1),
      maxTokens: Number(process.env.HOLO_AGENT_LOOP_MAX_TOKENS ?? 8192),
      // DeepSeek 推理模型默认开启 full reasoning，简单问题也要 60-120 秒。
      // agent_loop 的复杂 JSON 协议需要一定推理能力才能遵循（none 会输出无效格式），
      // low 模式在 2-5 秒内响应且能正确输出结构化 JSON。
      reasoningEffort: process.env.HOLO_AGENT_LOOP_REASONING_EFFORT ?? "low",
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
    // 中文数字智能归一化：计数场景（二十元→20元）转阿拉伯数字，成语/概数保留中文。
    // 默认开启，设 HOLO_ASR_CHINESE_NUMBER_CONVERSION=false 可关闭。
    chineseNumberConversionEnabled: process.env.HOLO_ASR_CHINESE_NUMBER_CONVERSION !== "false",
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
  subscription: {
    appleVerificationMode: process.env.HOLO_APPLE_VERIFICATION_MODE ?? "disabled",
  },
  // AI 内容安全审核（App Store Guideline 1.2）：阿里云文本审核增强版。
  // 未配置 AccessKey 时降级放行，配置后自动生效。
  moderation: {
    enabled: process.env.HOLO_MODERATION_ENABLED !== "false",
    accessKeyId: process.env.ALIBABA_CLOUD_ACCESS_KEY_ID ?? "",
    accessKeySecret: process.env.ALIBABA_CLOUD_ACCESS_KEY_SECRET ?? "",
    endpoint: process.env.HOLO_MODERATION_ENDPOINT ?? "green-cip.cn-shanghai.aliyuncs.com",
    service: process.env.HOLO_MODERATION_SERVICE ?? "chat_detection_pro",
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
    subscription: {
      ...DEFAULT_CONFIG.subscription,
      ...overrides.subscription,
    },
    moderation: {
      ...DEFAULT_CONFIG.moderation,
      ...overrides.moderation,
    },
    asrProvider: overrides.asrProvider,
    appleIdentityVerifier: overrides.appleIdentityVerifier,
    holoSessionService: overrides.holoSessionService,
    adminLogStore: overrides.adminLogStore,
    usageStore: overrides.usageStore,
    quotaActionLedgerStore: overrides.quotaActionLedgerStore,
    entitlementStore: overrides.entitlementStore,
    acceptanceStore: overrides.acceptanceStore,
    appleReceiptVerifier: overrides.appleReceiptVerifier,
    providerOverrides: overrides.providerOverrides,
    contentReportStore: overrides.contentReportStore,
    contentModeration: overrides.contentModeration,
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
    contentCaptureEnabled: process.env.HOLO_LOG_CAPTURE_CONTENT === "true",
    logRetentionDays: Number(process.env.HOLO_LOG_RETENTION_DAYS ?? 30),
    dbPath: process.env.HOLO_DB_PATH ?? "/data/holo-backend.db",
  };
}
