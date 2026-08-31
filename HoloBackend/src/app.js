import { Hono } from "hono";
import { randomBytes, randomUUID } from "node:crypto";

import { createErrorResponse, GatewayError, publicMessage } from "./errors.js";
import { createInMemoryUsageStore } from "./usage/inMemoryUsageStore.js";
import { createSqliteUsageStore } from "./usage/sqliteUsageStore.js";
import { createMockChatProvider } from "./providers/mockChatProvider.js";
import { createOpenAICompatibleProvider } from "./providers/openAICompatibleProvider.js";
import { createMockAsrProvider } from "./providers/mockAsrProvider.js";
import { createDashScopeAsrProvider } from "./providers/dashScopeAsrProvider.js";
import { getFinanceCategoryCatalog } from "./catalog/financeCategoryCatalog.js";
import { validateAgentLoopContent } from "./agentResponseValidator.js";
import { createStepIdempotencyStore } from "./agent/stepIdempotencyStore.js";
import { createStepResponseCipher } from "./agent/stepResponseCipher.js";
import { getPrompt, listPrompts, listPromptMetadata, setDatabase } from "./prompts/promptRegistry.js";
import { normalizeChineseNumbers } from "./chineseNumberConverter.js";
import { loadConfig } from "./config.js";
import { createAdminLogStore, truncateText } from "./admin/adminLogStore.js";
import { registerAdminRoutes } from "./admin/adminRoutes.js";
import { createRequestLogger } from "./middleware/requestLogger.js";
import { createDatabase } from "./db/database.js";
import { createAppleIdentityVerifier } from "./auth/appleIdentityVerifier.js";
import { createAppleRevokeService } from "./auth/appleRevokeService.js";
import { createHoloSessionService } from "./auth/holoSession.js";
import { requireInternalDiagnostics } from "./auth/internalDiagnosticsAuth.js";
import { injectServerPrompt } from "./prompts/serverPromptPolicy.js";
import { buildDeterministicIntentCompletion } from "./intentResponseStabilizer.js";
import { createEntitlementStore } from "./subscription/entitlementStore.js";
import { createAcceptanceStore } from "./subscription/acceptanceStore.js";
import { createFeatureFlagStore } from "./subscription/featureFlagStore.js";
import { createEntitlementResolver } from "./subscription/entitlementResolver.js";
import { createAppleReceiptVerifier } from "./subscription/appleReceiptVerifier.js";
import { HOLO_PLUS_PRODUCT_IDS } from "./subscription/productIds.js";
import { createQuotaActionLedgerStore } from "./usage/quotaActionLedgerStore.js";
import { getQuotaRule, QUOTA_TYPES } from "./usage/quotaPolicy.js";
import { createContentReportStore } from "./reports/contentReportStore.js";
import { createFeedbackStore } from "./feedback/feedbackStore.js";
import { createAgentTelemetryStore } from "./agent/agentTelemetryStore.js";
import { createCloudAnalysisTaskStore } from "./agent/cloudAnalysisTaskStore.js";
import { createCloudAnalysisExecutor } from "./agent/cloudAnalysisExecutor.js";
import { createDeviceTokenStore } from "./push/deviceTokenStore.js";
import { createApnsSender } from "./push/apnsSender.js";
import { createContentModerationService } from "./moderation/contentModerationService.js";

const CLIENT_ROUTING_FIELDS = ["baseURL", "baseUrl", "apiKey", "provider", "model"];

// 对客户端仍是普通 JSON 响应；网关到上游内部改用流式拉取，
// 避免长结构化任务在首字节前被 30s 网络空闲墙切断。
const INTERNAL_STREAM_COMPLETION_PURPOSES = new Set([
  "agent_loop",
  "insight",
  "memory_observer",
  "memory_domain_extraction",
  "memory_cross_domain_fusion",
]);

function buildAdminReleaseStatus(config, agentStepEncryption) {
  return {
    ok: true,
    service: "holo-ai-gateway",
    generatedAt: new Date().toISOString(),
    release: {
      commit: process.env.HOLO_RELEASE_COMMIT ?? null,
      sourceDigest: process.env.HOLO_RELEASE_SOURCE_DIGEST ?? null,
      buildTime: process.env.HOLO_RELEASE_BUILD_TIME ?? null,
    },
    prompts: listPromptMetadata().map((metadata) => ({
      ...metadata,
      content: getPrompt(metadata.type)?.content ?? "",
    })),
    routes: sanitizeRoutes(config.routes),
    database: {
      configured: Boolean(config.dbPath),
      path: undefined,
    },
    security: {
      agentStepIdempotencyResponseEncryption: agentStepEncryption?.algorithm ?? "unavailable",
    },
  };
}

function buildPublicReleaseStatus() {
  return {
    ok: true,
    service: "holo-ai-gateway",
    release: {
      commit: process.env.HOLO_RELEASE_COMMIT ?? null,
      sourceDigest: process.env.HOLO_RELEASE_SOURCE_DIGEST ?? null,
      buildTime: process.env.HOLO_RELEASE_BUILD_TIME ?? null,
    },
  };
}

function sanitizeRoutes(routes) {
  return Object.fromEntries(
    Object.entries(routes).map(([purpose, route]) => [
      purpose,
      {
        provider: route.provider,
        model: route.model,
        temperature: route.temperature,
        maxTokens: route.maxTokens,
        requestLimits: route.requestLimits ? { ...route.requestLimits } : undefined,
      },
    ]),
  );
}

export function createApp(overrides = {}) {
  const config = loadConfig(overrides);
  const app = new Hono();

  // 生产必须显式注入持久密钥；开发/测试可使用进程内临时密钥。
  // 在创建数据库前校验，避免密钥缺失时仍打开生产数据文件。
  const stepResponseCipher = config.agentStepIdempotencyStore
    ? null
    : createStepResponseCipher({
        primaryKey: config.agentStepIdempotencyEncryptionKey,
        previousKeys: config.agentStepIdempotencyPreviousEncryptionKeys,
        allowEphemeral: config.runtimeEnvironment !== "production",
      });

  // SQLite 数据库（可选，测试时可以不传）
  const database = config.database ?? createDatabase({ dbPath: config.dbPath });

  // 注入数据库到 Prompt 管理
  setDatabase(database.db);

  const usageStore = config.usageStore ?? createSqliteUsageStore(database.db);
  const entitlementStore = config.entitlementStore ?? createEntitlementStore(database.db);
  const acceptanceStore = config.acceptanceStore ?? createAcceptanceStore(database.db);
  const entitlementResolver = createEntitlementResolver({ entitlementStore, acceptanceStore });
  const featureFlagStore = config.featureFlagStore ?? createFeatureFlagStore(database.db);
  const quotaActionLedgerStore =
    config.quotaActionLedgerStore ?? createQuotaActionLedgerStore(database.db);
  const appleReceiptVerifier =
    config.appleReceiptVerifier ?? createAppleReceiptVerifier(config.subscription);
  const stepIdempotencyStore =
    config.agentStepIdempotencyStore
      ?? createStepIdempotencyStore(database.db, { responseCipher: stepResponseCipher });
  app.agentStepIdempotencyEncryption = stepIdempotencyStore.encryptionMetadata?.() ?? null;
  // TTL 清理定时器：测试注入 fake store 时不启动，避免定时器泄漏
  const agentStepCleanup = config.agentStepIdempotencyStore
    ? { stop() {} }
    : startAgentStepCleanupTimer(stepIdempotencyStore, config.agentStepIdempotencyCleanupIntervalMs);
  app.agentStepIdempotencyCleanup = agentStepCleanup;
  const adminLogStore =
    config.adminLogStore ??
    createAdminLogStore({
      maxEntries: config.admin.logMaxEntries,
      maxDetailChars: config.admin.logDetailMaxChars,
      db: database.db,
      contentCaptureEnabled: config.contentCaptureEnabled,
    });
  const contentReportStore = config.contentReportStore ?? createContentReportStore(database.db);
  const feedbackStore =
    config.feedbackStore ?? createFeedbackStore(database.db, { imagesDir: config.feedbackImagesDir });
  const agentTelemetryStore =
    config.agentTelemetryStore ?? createAgentTelemetryStore(database.db);
  // 云端异步分析（二期 M1）：密钥未配置时优雅禁用（端点统一 503），配置后自动启用——
  // M1 部署不强制先配 ECS 环境变量，零风险上线；生产密钥纪律与 step 缓存一致。
  let cloudAnalysisTaskStore = config.cloudAnalysisTaskStore ?? null;
  if (!cloudAnalysisTaskStore && config.cloudAnalysisEncryptionKey) {
    try {
      cloudAnalysisTaskStore = createCloudAnalysisTaskStore(database.db, {
        encryptionKey: config.cloudAnalysisEncryptionKey,
      });
    } catch (error) {
      console.error("[holo-backend] 云端分析密钥无效，功能保持禁用:", error?.message ?? error);
    }
  }
  // 云端分析任务 7 天过期兜底清理（复用同一清理节拍；store 未启用时无操作）
  if (cloudAnalysisTaskStore) {
    startAgentStepCleanupTimer(
      { purgeExpired: (now) => cloudAnalysisTaskStore.purgeExpired(now) },
      config.agentStepIdempotencyCleanupIntervalMs,
    );
  }
  const providers = createProviders(config);
  const asrProvider = createAsrProvider(config);
  // 云端执行器（M2a）：store 启用且 agent_loop route 可用时创建；
  // 执行采用进程内 fire-and-forget + 启动扫描 queued 孤儿（单实例，无队列基建）。
  // 必须在 providers 声明之后（生产密钥启用时曾因顺序错误创建失败）。
  let cloudAnalysisExecutor = config.cloudAnalysisExecutor ?? null;
  // 推送通知（云端分析完成）：token 行 → APNs 发送；环境探测结果回写、
  // 410 卸载删行都在 notifier 内闭环；密钥未配置时整体 no-op（不影响分析链路）。
  const deviceTokenStore = config.deviceTokenStore ?? createDeviceTokenStore(database.db);
  let apnsSender = config.apnsSender ?? null;
  if (!apnsSender) {
    const rawKey = config.auth.apns.keyContent;
    const keyPem = rawKey.startsWith("base64:")
      ? Buffer.from(rawKey.slice("base64:".length), "base64").toString("utf8")
      : rawKey;
    if (config.auth.apns.keyId && keyPem.trim()) {
      apnsSender = createApnsSender({
        keyPem,
        keyId: config.auth.apns.keyId,
        teamId: config.auth.apns.teamId,
        bundleId: config.auth.apns.bundleId,
        log: (message) => console.log("[apns]", message),
      });
    }
  }
  const analysisPushNotifier = apnsSender?.configured
    ? {
        async notifyTaskCompleted(deviceId, { title, body }) {
          const row = deviceTokenStore.get(deviceId);
          if (!row) return;
          const result = await apnsSender.send({
            token: row.token,
            environment: row.environment ?? undefined,
            title,
            body,
          });
          if (result.ok) {
            if (result.environment && result.environment !== row.environment) {
              deviceTokenStore.markEnvironment(deviceId, result.environment);
            }
          } else if (result.reason === "unregistered") {
            deviceTokenStore.remove(deviceId);
          } else {
            console.log("[apns] 推送未送达:", JSON.stringify({
              deviceId, reason: result.reason, apnsReason: result.apnsReason ?? null, status: result.status ?? null,
            }));
          }
        },
      }
    : null;
  if (cloudAnalysisTaskStore && !cloudAnalysisExecutor && config.routes.agent_loop) {
    try {
      cloudAnalysisExecutor = createCloudAnalysisExecutor({
        taskStore: cloudAnalysisTaskStore,
        providers,
        route: config.routes.agent_loop,
        pushNotifier: analysisPushNotifier,
        quotaLedger: quotaActionLedgerStore,
        entitlementResolver,
      });
    } catch (error) {
      console.error("[holo-backend] 云端分析执行器创建失败（任务将停留在 queued）:", error?.message ?? error);
    }
  }
  if (cloudAnalysisExecutor) {
    // 启动扫描：进程重启后 queued 孤儿重新执行（任务级重跑即幂等）
    setImmediate(() => {
      resumeQueuedCloudAnalysisTasks(cloudAnalysisTaskStore, cloudAnalysisExecutor);
    });
  }
  const captureAiCallLogs = config.aiCallLogs.enabled;
  const appleIdentityVerifier = config.appleIdentityVerifier ?? createAppleIdentityVerifier({
    clientIds: config.auth.appleClientIds,
  });
  const appleRevokeService = config.appleRevokeService ?? createAppleRevokeService({
    teamId: config.auth.appleRevoke?.teamId,
    keyId: config.auth.appleRevoke?.keyId,
    clientId: config.auth.appleRevoke?.clientId,
    privateKeyPem: config.auth.appleRevoke?.privateKeyPem,
  });
  const holoSessionService = config.holoSessionService ?? createConfiguredSessionService(config.auth);
  const contentModeration =
    config.contentModeration ?? createContentModerationService(config.moderation);

  // 请求耗时日志中间件
  const requestLogger = createRequestLogger(database.db);
  app.use('*', requestLogger.middleware);
  requestLogger.startFlushTimer();
  requestLogger.cleanupOld();

  const runAdminTestChat = createAdminTestChatRunner({
    config,
    providers,
    logStore: adminLogStore,
  });

  registerAdminRoutes(app, {
    config,
    logStore: adminLogStore,
    featureFlagStore,
    runTestChat: runAdminTestChat,
    getReleaseStatus: () => buildAdminReleaseStatus(
      config,
      app.agentStepIdempotencyEncryption,
    ),
    reportStore: contentReportStore,
    feedbackStore,
    db: database.db,
    acceptanceStore,
    entitlementResolver,
  });

  app.get("/v1/health", (context) => {
    return context.json({
      ok: true,
      service: "holo-ai-gateway",
    });
  });

  app.post("/v1/auth/apple/session", async (context) => {
    try {
      if (!holoSessionService) {
        throw new GatewayError("AUTH_UNAVAILABLE", "Holo session secret is not configured", 503);
      }
      const request = await readJson(context);
      let identity;
      try {
        identity = await appleIdentityVerifier.verify(request.identityToken);
      } catch {
        throw new GatewayError("INVALID_APPLE_IDENTITY", "Apple identity token is invalid", 401);
      }
      const token = await holoSessionService.issue(identity.sub);
      const session = await holoSessionService.verify(token);
      context.header("Cache-Control", "no-store");
      return context.json({
        token,
        expiresAt: session.expiresAt,
        internalDiagnostics: session.internalDiagnostics,
      });
    } catch (error) {
      return createErrorResponse(context, error);
    }
  });

  // App Store Guideline 5.1.1v：账号删除时撤销 Sign in with Apple 凭证。
  // 客户端在删除账号前把用户的 identity token 发到这里，后端用 .p8 私钥签 client_secret
  // 后调 Apple /auth/revoke 撤销。先验证 identity token，防止用任意字符串滥用撤销端点。
  app.post("/v1/auth/apple/revoke", async (context) => {
    try {
      const request = await readJson(context);
      try {
        await appleIdentityVerifier.verify(request.identityToken);
      } catch {
        throw new GatewayError("INVALID_APPLE_IDENTITY", "Apple identity token is invalid", 401);
      }
      if (!appleRevokeService.isConfigured()) {
        throw new GatewayError("APPLE_REVOKE_NOT_CONFIGURED", "Apple credential revocation is not configured", 503);
      }
      await appleRevokeService.revoke(request.identityToken);
      context.header("Cache-Control", "no-store");
      return context.json({ ok: true });
    } catch (error) {
      return createErrorResponse(context, error);
    }
  });

  app.get("/v1/internal/ai-logs/:requestId", async (context) => {
    try {
      await requireInternalDiagnostics(context, holoSessionService);
      const entry = adminLogStore.get(context.req.param("requestId"));
      if (!entry) {
        throw new GatewayError("INTERNAL_LOG_NOT_FOUND", "Internal log is not in the hot cache", 404);
      }
      context.header("Cache-Control", "no-store");
      return context.json({ log: entry });
    } catch (error) {
      return createErrorResponse(context, error);
    }
  });

  app.get("/v1/release/status", (context) => {
    return context.json(buildPublicReleaseStatus());
  });

  if (overrides.exposePromptEndpointsForTests === true) {
    app.get("/v1/prompts", (context) => {
      return context.json({
        prompts: listPrompts(),
      });
    });

    app.get("/v1/prompts/meta", (context) => {
      return context.json({
        prompts: listPromptMetadata(),
      });
    });

    app.get("/v1/prompts/:type", (context) => {
      try {
        const prompt = getPrompt(context.req.param("type"));
        if (!prompt) {
          throw new GatewayError("PROMPT_NOT_FOUND", "Prompt type is not supported", 404);
        }
        return context.json(prompt);
      } catch (error) {
        return createErrorResponse(context, error);
      }
    });
  }

  app.get("/v1/catalog/finance-categories", (context) => {
    return context.json(getFinanceCategoryCatalog());
  });

  app.post("/v1/app-attest/challenge", async (context) => {
    try {
      await readJson(context);
      return context.json({
        challenge: randomBytes(32).toString("base64url"),
        expiresInSeconds: 300,
      });
    } catch (error) {
      return createErrorResponse(context, error);
    }
  });

  app.post("/v1/app-attest/assert", async (context) => {
    try {
      const request = await readJson(context);

      if (!config.auth.enforceAppAttest && request.debug === true) {
        return context.json({
          ok: true,
          mode: "debug",
        });
      }

      throw new GatewayError("APP_ATTEST_REQUIRED", "App Attest is not implemented yet", 401);
    } catch (error) {
      return createErrorResponse(context, error);
    }
  });

  const subscriptionStatusFor = (deviceId) => {
    const entitlement = entitlementResolver.resolve(deviceId);
    const status = buildSubscriptionStatus(entitlement, quotaActionLedgerStore);
    // 服务端可控行为开关（admin 改完即生效，客户端下次刷新订阅状态时应用）
    status.featureFlags = featureFlagStore.getAll();
    return status;
  };

  app.get("/v1/subscription/status", (context) => {
    try {
      const deviceId = getDeviceId(context, config);
      context.header("Cache-Control", "no-store");
      return context.json(subscriptionStatusFor(deviceId));
    } catch (error) {
      return createErrorResponse(context, error);
    }
  });

  app.post("/v1/subscription/sync", async (context) => {
    try {
      const deviceId = getDeviceId(context, config);
      const request = await readJson(context);
      const verified = await appleReceiptVerifier.verify(request);
      entitlementStore.upsertVerified(deviceId, verified);
      context.header("Cache-Control", "no-store");
      return context.json(subscriptionStatusFor(deviceId));
    } catch (error) {
      return createErrorResponse(context, error);
    }
  });

  app.post("/v1/subscription/acceptance", async (context) => {
    try {
      await requireInternalDiagnostics(context, holoSessionService);
      const deviceId = getDeviceId(context, config);
      const request = await readJson(context);
      if (request.mode === "followPurchase") {
        acceptanceStore.clear(deviceId);
      } else if (request.mode === "free" || request.mode === "plus") {
        acceptanceStore.set(deviceId, request.mode);
      } else {
        throw new GatewayError("INVALID_ACCEPTANCE_MODE", "Unsupported acceptance mode", 400);
      }
      context.header("Cache-Control", "no-store");
      return context.json(subscriptionStatusFor(deviceId));
    } catch (error) {
      return createErrorResponse(context, error);
    }
  });

  app.post("/v1/subscription/acceptance/reset", async (context) => {
    try {
      await requireInternalDiagnostics(context, holoSessionService);
      const deviceId = getDeviceId(context, config);
      const entitlement = entitlementResolver.resolve(deviceId);
      if (entitlement.source !== "acceptance") {
        throw new GatewayError(
          "ACCEPTANCE_MODE_REQUIRED",
          "Quota reset is only available in acceptance mode",
          400,
        );
      }
      quotaActionLedgerStore.reset(entitlement.usageSubjectId);
      context.header("Cache-Control", "no-store");
      return context.json(subscriptionStatusFor(deviceId));
    } catch (error) {
      return createErrorResponse(context, error);
    }
  });

  app.post("/v1/ai/chat/completions", async (context) => {
    let quotaReservation = null;
    try {
      const request = await readJson(context);
      validateChatRequest(request);
      rejectClientRouting(request);

      const purpose = request.purpose ?? "chat";
      const route = config.routes[purpose];
      if (!route) {
        throw new GatewayError("UNKNOWN_PURPOSE", `Unsupported purpose: ${purpose}`, 400);
      }

      const deviceId = getDeviceId(context, config);
      const entitlement = entitlementResolver.resolve(deviceId);
      const quotaType = quotaTypeForPurpose(purpose);
      const quotaActionId = resolveQuotaActionId(request, purpose);
      const requestLimits = resolveChatRequestLimits(config, route);
      const usage = usageStore.consume({
        deviceId,
        purpose,
        minuteLimit: requestLimits.perMinute,
        dailyLimit: requestLimits.perDay,
      });
      if (!usage.allowed) {
        throw new GatewayError("RATE_LIMITED", "Device rate limit exceeded", 429);
      }

      const provider = providers.get(route.provider);
      if (!provider) {
        throw new GatewayError("MODEL_UNAVAILABLE", `Provider unavailable: ${route.provider}`, 503);
      }

      if (quotaType) {
        quotaReservation = {
          subjectId: entitlement.usageSubjectId,
          tier: entitlement.tier,
          quotaType,
          actionId: quotaActionId,
        };
        const reservation = quotaActionLedgerStore.reserve(quotaReservation);
        if (!reservation.allowed) {
          const quotaError = quotaExceededError(reservation);
          if (captureAiCallLogs) {
            const quotaLogId = adminLogStore.startAiCall({
              deviceId,
              purpose,
              provider: route.provider,
              model: route.model,
              stream: request.stream === true,
              request: {
                messageCount: request.messages.length,
                messageRoles: request.messages.map((message) => message.role),
                responseFormat: request.response_format ?? null,
              },
            });
            adminLogStore.finishAiCall(quotaLogId, {
              status: "quota_exceeded",
              error: serializeError(quotaError),
              response: quotaError.details,
            });
          }
          throw quotaError;
        }
        context.header("X-Holo-Quota-Type", quotaType);
      }

      const serverPrompt = injectServerPrompt(purpose, request.messages);
      const isAgentLoop = purpose === "agent_loop";
      const upstreamRequest = {
        purpose,
        messages: serverPrompt.messages,
        stream: request.stream === true,
        model: route.model,
        temperature: route.temperature,
        maxTokens: route.maxTokens,
        responseFormat: request.response_format,
        reasoningEffort: route.reasoningEffort,
        // agent_loop 是 step 幂等请求：锁屏/切后台导致的客户端断开是系统行为而非用户意图，
        // 不能连坐取消上游模型调用（2026-08-30 锁屏事故：30s 后台窗口内模型边算边被掐，
        // 缓存永远建不起来，4 次重试全部从头算全部作废）。断开后让上游算完并落幂等缓存，
        // 客户端重发同 stepID 直接命中秒回，每个后台窗口都能推进一步。
        // 其余 purpose（含流式 chat）保持断开即止，不为已离开的连接浪费上游算力。
        clientSignal: isAgentLoop ? undefined : context.req.raw.signal,
      };
      const stepIdentity = resolveAgentStepIdentity(isAgentLoop, request);
      const logId = captureAiCallLogs
        ? adminLogStore.startAiCall({
            deviceId,
            purpose,
            provider: route.provider,
            model: route.model,
            promptType: serverPrompt.promptType,
            promptVersion: serverPrompt.promptVersion,
            stream: upstreamRequest.stream,
            request: isAgentLoop
              ? {
                  runId: request.runId ?? null,
                  stepId: request.stepId ?? null,
                  messageCount: upstreamRequest.messages.length,
                  messageRoles: upstreamRequest.messages.map((message) => message.role),
                  contentLength: upstreamRequest.messages.reduce(
                    (total, message) => total + (message.content?.length ?? 0),
                    0,
                  ),
                  responseFormat: request.response_format ?? null,
                }
              : {
                  messages: upstreamRequest.messages,
                  responseFormat: request.response_format ?? null,
                  temperature: route.temperature,
                  maxTokens: route.maxTokens,
                },
          })
        : null;

      if (logId) {
        context.header("X-Holo-Request-Id", logId);
      }

      // AI 内容安全审核（App Store Guideline 1.2）：调用上游模型前审核用户输入。
      // 命中违规则释放配额、记录日志并返回拦截响应，不把违规内容送到模型。
      const moderationResult = await contentModeration.moderate(
        extractLastUserText(upstreamRequest.messages),
      );
      if (!moderationResult.passed) {
        releaseQuota(quotaActionLedgerStore, quotaReservation);
        if (logId) {
          adminLogStore.finishAiCall(logId, {
            status: "moderation_blocked",
            response: {
              labels: moderationResult.labels,
              riskLevel: moderationResult.riskLevel,
            },
          });
        }
        if (upstreamRequest.stream) {
          return streamModerationBlocked({ requestId: logId, quotaType });
        }
        return context.json(moderationRefusalCompletion(), 200);
      }

      if (upstreamRequest.stream) {
        return streamChat(context, provider, upstreamRequest, {
          logStore: logId ? adminLogStore : null,
          logId,
          requestId: logId,
          quotaType,
          onSuccess: () => commitQuota(quotaActionLedgerStore, quotaReservation),
          onFailure: () => releaseQuota(quotaActionLedgerStore, quotaReservation),
        });
      }

      let acquiredStep = null;
      try {
        if (stepIdentity) {
          const stepGate = acquireAgentStep(
            stepIdempotencyStore,
            stepIdentity,
            config.agentStepIdempotencyTtlSeconds,
          );
          if (stepGate.type === "conflict") {
            logAgentStepEvent("agent_step_conflict", stepIdentity, { errorCode: "STEP_ID_CONFLICT" });
            throw new GatewayError("STEP_ID_CONFLICT", "Step was already used with a different payload", 409);
          }
          if (stepGate.type === "in_progress") {
            logAgentStepEvent("agent_step_in_progress", stepIdentity, { errorCode: "STEP_IN_PROGRESS" });
            throw new GatewayError("STEP_IN_PROGRESS", "Step is currently in progress", 409);
          }
          if (stepGate.type === "failed_final") {
            logAgentStepEvent("agent_step_failed_final_replayed", stepIdentity, {
              errorCode: stepGate.record.errorCode ?? "UPSTREAM_ERROR",
            });
            throw new GatewayError(
              stepGate.record.errorCode ?? "UPSTREAM_ERROR",
              "Step previously failed with a terminal error",
              stepGate.record.errorStatus ?? 502,
            );
          }
          if (stepGate.type === "completed") {
            logAgentStepEvent("agent_step_idempotency_hit", stepIdentity);
            if (logId) {
              adminLogStore.finishAiCall(logId, {
                status: "success",
                response: {
                  status: "idempotency_hit",
                  runId: stepIdentity.runId,
                  stepId: stepIdentity.stepId,
                  usage: stepGate.record.usage ?? null,
                },
              });
            }
            context.header("X-Holo-Step-Idempotency", "hit");
            commitQuota(quotaActionLedgerStore, quotaReservation);
            return context.json(JSON.parse(stepGate.record.response));
          }
          acquiredStep = stepIdentity;
          logAgentStepEvent("agent_step_acquired", stepIdentity);
        }
        const deterministicIntentResult = purpose === "intent"
          ? buildDeterministicIntentCompletion(upstreamRequest.messages, route.model)
          : null;
        // 长结构化任务用流式拉取（provider 支持时）。返回结构与
        // complete() 一致，下游的校验、幂等、审核和日志契约不变。
        const useStream = INTERNAL_STREAM_COMPLETION_PURPOSES.has(purpose)
          && typeof provider.completeViaStream === "function";
        const upstreamComplete = useStream
          ? provider.completeViaStream.bind(provider)
          : provider.complete.bind(provider);
        const result = deterministicIntentResult ?? (purpose === "insight"
          ? await completeInsightWithRetry(upstreamComplete, upstreamRequest)
          : await upstreamComplete(upstreamRequest));
        if (purpose === "agent_loop") {
          const agentContent = result?.choices?.[0]?.message?.content;
          const agentValidation = validateAgentLoopContent(agentContent ?? "");
          if (!agentValidation.valid) {
            // 向后兼容已发布客户端：Agent 模型偶发输出坏 JSON 时，不能用 502
            // 提前终止整个用户任务。返回一个可解码的继续推理轮，让客户端正常
            // 消耗本轮预算、提交新 step，并把恢复标记带给下一轮模型。
            result.choices[0].message.content = JSON.stringify({
              status: "need_more_analysis",
              reasoning: [
                "[HOLO_AGENT_RESPONSE_RECOVERY_V1]",
                "上一轮输出未通过 Agent 协议校验；请丢弃坏结构并重新生成完整 JSON。",
              ].join("\n"),
              toolRequests: [],
              claims: [],
              warnings: ["response_contract_recovery"],
            });
            if (stepIdentity) {
              logAgentStepEvent("agent_response_recovery_envelope", stepIdentity, {
                errorCode: "INVALID_AGENT_JSON",
              });
            }
          } else {
            if (stepIdentity && agentValidation.repairs?.length > 0) {
              logAgentStepEvent("agent_response_repaired", stepIdentity, {
                repairs: agentValidation.repairs,
              });
            }
            result.choices[0].message.content = agentValidation.content;
          }
        }
        // 非流式输出审核：模型生成内容命中违规时替换为拒绝文案（App Store Guideline 1.2）。
        // 流式输出不做审核，靠输入审核 + 上游模型自身安全兜底。
        const outputMessage = result?.choices?.[0]?.message;
        if (outputMessage) {
          const outputModeration = await contentModeration.moderate(
            extractMessageText(outputMessage.content),
          );
          if (!outputModeration.passed) {
            outputMessage.content = MODERATION_REFUSAL_MESSAGE;
            result.choices[0].finish_reason = "content_filter";
            result.moderation_blocked = true;
          }
        }
        if (acquiredStep) {
          stepIdempotencyStore.markCompleted(
            acquiredStep.runId,
            acquiredStep.stepId,
            result,
            result?.usage ?? null,
          );
          logAgentStepEvent("agent_step_completed", acquiredStep, {
            inputTokens: result?.usage?.prompt_tokens ?? null,
            outputTokens: result?.usage?.completion_tokens ?? null,
          });
        }
        if (logId) {
          adminLogStore.finishAiCall(logId, {
            status: "success",
            response: isAgentLoop
              ? summarizeAgentLoopResponse(result)
              : purpose === "insight"
                ? summarizeInsightResponse(result)
                : result,
          });
        }
        commitQuota(quotaActionLedgerStore, quotaReservation);
        return context.json(result);
      } catch (error) {
        if (acquiredStep) {
          recordAgentStepFailure(stepIdempotencyStore, acquiredStep, error);
          logAgentStepEvent("agent_step_failed", acquiredStep, {
            errorCode: error instanceof GatewayError ? error.code : "UPSTREAM_ERROR",
          });
        }
        if (logId) {
          adminLogStore.finishAiCall(logId, {
            status: "error",
            error: serializeError(error),
          });
        }
        throw error;
      }
    } catch (error) {
      releaseQuota(quotaActionLedgerStore, quotaReservation);
      return createErrorResponse(context, error);
    }
  });

  // P2（方案 §5.2）：想法语义候选召回的 embedding 批量端点。
  // 鉴权/限流与 chat 端点同范式；独立 purpose 限流桶（默认 20/分、120/天，.env 可调）。
  // 不做 moderation：正文在 thought_organization 分类时已审核，同一内容不重复消耗审核调用。
  // 响应不含正文，服务端日志不记录文本与向量内容。
  app.post("/v1/ai/embeddings", async (context) => {
    try {
      const request = await readJson(context);
      const texts = request?.texts;
      if (
        !Array.isArray(texts) || texts.length === 0 || texts.length > 16
        || texts.some((text) => typeof text !== "string" || text.length === 0 || text.length > 2000)
      ) {
        throw new GatewayError("INVALID_REQUEST", "texts must be 1-16 non-empty strings (max 2000 chars each)", 400);
      }
      const purpose = request.purpose ?? "thought_embedding";
      if (purpose !== "thought_embedding") {
        throw new GatewayError("UNKNOWN_PURPOSE", `Unsupported purpose: ${purpose}`, 400);
      }

      const route = config.routes[purpose];
      if (!route) {
        throw new GatewayError("UNKNOWN_PURPOSE", `Unsupported purpose: ${purpose}`, 400);
      }

      const deviceId = getDeviceId(context, config);
      const requestLimits = {
        perMinute: route.requestLimits?.perMinute ?? config.limits.chatRequestsPerMinute,
        perDay: route.requestLimits?.perDay ?? config.limits.chatRequestsPerDay,
      };
      const usage = usageStore.consume({
        deviceId,
        purpose,
        minuteLimit: requestLimits.perMinute,
        dailyLimit: requestLimits.perDay,
      });
      if (!usage.allowed) {
        throw new GatewayError("RATE_LIMITED", "Device rate limit exceeded", 429);
      }

      const provider = providers.get(route.provider);
      if (!provider || typeof provider.embed !== "function") {
        throw new GatewayError("MODEL_UNAVAILABLE", `Provider unavailable: ${route.provider}`, 503);
      }

      const result = await provider.embed({
        purpose,
        texts,
        model: route.model,
        dimensions: route.dimensions,
        clientSignal: context.req.raw.signal,
      });
      if (result.vectors.length !== texts.length) {
        throw new GatewayError("MODEL_UNAVAILABLE", "Embeddings count mismatch", 503);
      }

      context.header("Cache-Control", "no-store");
      return context.json({ model: result.model, dimensions: result.vectors[0]?.length ?? 0, vectors: result.vectors });
    } catch (error) {
      return createErrorResponse(context, error);
    }
  });

  app.post("/v1/asr/transcriptions", async (context) => {
    let quotaReservation = null;
    try {
      const deviceId = getDeviceId(context, config);
      const formData = await context.req.formData();
      const audio = formData.get("audio");
      if (!isUploadedFile(audio)) {
        throw new GatewayError("INVALID_REQUEST", "audio file is required", 400);
      }

      if (audio.size > config.limits.asrMaxBytes) {
        throw new GatewayError("AUDIO_TOO_LARGE", "Audio file is too large", 413);
      }

      const audioBuffer = await audio.arrayBuffer();
      const entitlement = entitlementResolver.resolve(deviceId);
      const durationSeconds = resolveAudioDurationSeconds(
        formData.get("durationSeconds")?.toString(),
        audioBuffer,
      );
      validateAsrDuration(entitlement.tier, durationSeconds);

      const usage = usageStore.consume({
        deviceId,
        purpose: "asr",
        minuteLimit: config.limits.asrRequestsPerMinute,
        dailyLimit: config.limits.asrRequestsPerDay,
      });
      if (!usage.allowed) {
        throw new GatewayError("RATE_LIMITED", "Device rate limit exceeded", 429);
      }

      quotaReservation = {
        subjectId: entitlement.usageSubjectId,
        tier: entitlement.tier,
        quotaType: QUOTA_TYPES.asr,
        actionId: normalizedActionId(formData.get("usageActionId")?.toString()) ?? randomUUID(),
      };
      const reservation = quotaActionLedgerStore.reserve(quotaReservation);
      if (!reservation.allowed) throw quotaExceededError(reservation);
      context.header("X-Holo-Quota-Type", QUOTA_TYPES.asr);

      const logId = captureAiCallLogs
        ? adminLogStore.startAiCall({
            deviceId,
            purpose: "asr_transcription",
            provider: "dashscope",
            model: config.asr.model,
            stream: false,
            asrFileType: audio.type,
            request: { asr: true },
          })
        : null;

      try {
        const result = await asrProvider.transcribe({
          audio: audioBuffer,
          fileName: audio.name,
          mimeType: audio.type,
          locale: formData.get("locale")?.toString() ?? null,
        });
        // 中文数字归一化（"一个"→"1个"）只服务 HoloAI 对话输入（LLM 解析量词/时间更稳）；
        // 想法/任务是记录原文的场景，保留用户口述原样。未携带 source 的旧客户端维持全量转换。
        const asrSource = formData.get("source")?.toString() ?? null;
        if (
          config.asr.chineseNumberConversionEnabled &&
          (asrSource === null || asrSource === "chat") &&
          typeof result.text === "string"
        ) {
          result.text = normalizeChineseNumbers(result.text);
        }
        if (logId) {
          const transcriptText = result.text ?? JSON.stringify(result);
          adminLogStore.finishAiCall(logId, {
            status: "success",
            response: result,
            asrResultLength: transcriptText.length,
          });
        }
        commitQuota(quotaActionLedgerStore, quotaReservation);
        return context.json(result);
      } catch (error) {
        if (logId) {
          adminLogStore.finishAiCall(logId, {
            status: "error",
            error: serializeError(error),
          });
        }
        throw error;
      }
    } catch (error) {
      releaseQuota(quotaActionLedgerStore, quotaReservation);
      return createErrorResponse(context, error);
    }
  });

  // AI 内容举报（App Store Guideline 1.2）
  // 鉴权：与聊天/语音一致，使用设备标识（X-Holo-Device-Id）。
  // 不复用 holoSession：该 session 仅用于内部诊断，且客户端在正式版不会携带。
  app.post("/v1/reports", async (context) => {
    try {
      const deviceId = getDeviceId(context, config);
      const request = await readJson(context);

      if (typeof request.messageId !== "string" || request.messageId.trim().length === 0) {
        throw new GatewayError("INVALID_REQUEST", "messageId is required", 400);
      }
      if (typeof request.reason !== "string" || request.reason.trim().length === 0) {
        throw new GatewayError("INVALID_REQUEST", "reason is required", 400);
      }
      if (request.reason.length > 200) {
        throw new GatewayError("INVALID_REQUEST", "reason is too long", 400);
      }

      const detail = typeof request.detail === "string" ? request.detail.slice(0, 1000) : null;
      const contentSnapshot = typeof request.contentSnapshot === "string"
        ? request.contentSnapshot.slice(0, 4000)
        : null;

      // 复用现有限流桶（rate_limits 表），purpose=report 独立计数
      const usage = usageStore.consume({
        deviceId,
        purpose: "report",
        minuteLimit: config.limits.reportRequestsPerMinute,
        dailyLimit: config.limits.reportRequestsPerDay,
      });
      if (!usage.allowed) {
        throw new GatewayError("REPORT_RATE_LIMITED", "Report rate limit exceeded", 429);
      }

      contentReportStore.create({
        deviceId,
        messageId: request.messageId.trim(),
        reason: request.reason.trim(),
        detail,
        contentSnapshot,
      });

      return context.json({ ok: true });
    } catch (error) {
      return createErrorResponse(context, error);
    }
  });

  // 用户反馈（设置页「反馈给开发者」）
  // 鉴权与举报一致：设备标识（X-Holo-Device-Id），无需登录态。
  // 图片以 base64 数组随 JSON 提交，解码校验 JPEG 魔数后写文件系统（见 feedbackStore）。
  const FEEDBACK_CATEGORIES = new Set(["suggestion", "issue", "other"]);
  const FEEDBACK_CONTACT_TYPES = new Set(["wechat", "qq", "email", "phone"]);
  app.post("/v1/feedback", async (context) => {
    try {
      const deviceId = getDeviceId(context, config);
      const request = await readJson(context);

      if (!FEEDBACK_CATEGORIES.has(request.category)) {
        throw new GatewayError("INVALID_REQUEST", "category must be suggestion | issue | other", 400);
      }
      if (typeof request.content !== "string" || request.content.trim().length === 0) {
        throw new GatewayError("INVALID_REQUEST", "content is required", 400);
      }

      const contactValue = typeof request.contactValue === "string" ? request.contactValue.trim().slice(0, 60) : null;
      const contactType = typeof request.contactType === "string" ? request.contactType : null;
      if (contactValue && !FEEDBACK_CONTACT_TYPES.has(contactType)) {
        throw new GatewayError("INVALID_REQUEST", "contactType must be wechat | qq | email | phone", 400);
      }

      const rawImages = Array.isArray(request.images) ? request.images : [];
      if (rawImages.length > 3) {
        throw new GatewayError("INVALID_REQUEST", "at most 3 images are allowed", 400);
      }
      const imageBuffers = rawImages.map((image) => {
        const buffer = Buffer.from(String(image), "base64");
        if (buffer.length < 4 || buffer[0] !== 0xff || buffer[1] !== 0xd8) {
          throw new GatewayError("INVALID_REQUEST", "images must be JPEG data", 400);
        }
        if (buffer.length > config.limits.feedbackMaxImageBytes) {
          throw new GatewayError("IMAGE_TOO_LARGE", "image exceeds size limit", 413);
        }
        return buffer;
      });

      // 复用现有限流桶（rate_limits 表），purpose=feedback 独立计数
      const usage = usageStore.consume({
        deviceId,
        purpose: "feedback",
        minuteLimit: config.limits.feedbackRequestsPerMinute,
        dailyLimit: config.limits.feedbackRequestsPerDay,
      });
      if (!usage.allowed) {
        throw new GatewayError("FEEDBACK_RATE_LIMITED", "Feedback rate limit exceeded", 429);
      }

      feedbackStore.create({
        deviceId,
        category: request.category,
        content: request.content.trim().slice(0, 2000),
        contactType: contactValue ? contactType : null,
        contactValue,
        appVersion: typeof request.appVersion === "string" ? request.appVersion.slice(0, 40) : null,
        osVersion: typeof request.osVersion === "string" ? request.osVersion.slice(0, 40) : null,
        imageBuffers,
      });

      return context.json({ ok: true });
    } catch (error) {
      return createErrorResponse(context, error);
    }
  });

  // ===== 云端异步分析（二期 M1：任务底座）=====
  // 生命周期：start 创建(uploading) → 上传快照(queued) → [M2 执行器接管 running→completed/failed]
  // → GET 回传结果即销毁密文 / DELETE 取消整行销毁 / 7 天过期兜底清理。
  // 隐私契约：快照/问题/失败原因/结果全部密文落存；完成/失败立即销毁输入侧数据。
  const requireCloudAnalysisStore = () => {
    if (!cloudAnalysisTaskStore) {
      throw new GatewayError("SERVICE_DISABLED", "Cloud analysis is not enabled", 503);
    }
    return cloudAnalysisTaskStore;
  };

  app.post("/v1/ai/agent/cloud/start", async (context) => {
    try {
      const store = requireCloudAnalysisStore();
      const deviceId = getDeviceId(context, config);
      const request = await readJson(context);

      const question = typeof request.question === "string" ? request.question.trim() : "";
      if (!question || question.length > 2000) {
        throw new GatewayError("INVALID_REQUEST", "question must be 1-2000 chars", 400);
      }
      // 任务类型白名单：deep_analysis=多轮 Agent 循环；period_replay=周期回放单轮生成
      const taskType = typeof request.taskType === "string" ? request.taskType : "deep_analysis";
      if (!["deep_analysis", "period_replay"].includes(taskType)) {
        throw new GatewayError("INVALID_REQUEST", `Unsupported taskType: ${taskType}`, 400);
      }

      const usage = usageStore.consume({
        deviceId,
        purpose: "cloud_analysis_start",
        minuteLimit: config.limits.cloudAnalysisStartsPerMinute,
        dailyLimit: config.limits.cloudAnalysisStartsPerDay,
      });
      if (!usage.allowed) {
        throw new GatewayError("RATE_LIMITED", "Device rate limit exceeded", 429);
      }

      const task = store.create({ deviceId, question, taskType });
      context.header("Cache-Control", "no-store");
      return context.json({ taskId: task.id, status: "uploading", expiresAt: task.expiresAt });
    } catch (error) {
      return createErrorResponse(context, error);
    }
  });

  app.put("/v1/ai/agent/cloud/:id/snapshot", async (context) => {
    try {
      const store = requireCloudAnalysisStore();
      const deviceId = getDeviceId(context, config);
      const task = store.get(context.req.param("id"));
      if (!task || task.device_id !== deviceId) {
        throw new GatewayError("NOT_FOUND", "Task not found", 404);
      }
      if (task.status !== "uploading") {
        throw new GatewayError("INVALID_STATE", `Snapshot already received (status=${task.status})`, 409);
      }
      const raw = await context.req.text();
      if (!raw || raw.length > config.limits.cloudAnalysisSnapshotMaxBytes) {
        throw new GatewayError("SNAPSHOT_TOO_LARGE", "Snapshot exceeds size limit", 413);
      }
      // 快照必须是合法 JSON 对象（各数据域的结构化全集）；原文即刻加密落存，不落明文日志
      let parsed;
      try {
        parsed = JSON.parse(raw);
      } catch {
        throw new GatewayError("INVALID_REQUEST", "Snapshot must be valid JSON", 400);
      }
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
        throw new GatewayError("INVALID_REQUEST", "Snapshot must be a JSON object", 400);
      }
      const attached = store.attachSnapshot({ id: task.id, snapshot: raw });
      if (!attached) {
        throw new GatewayError("INVALID_STATE", "Snapshot already received", 409);
      }
      // 快照齐备即触发云端执行（fire-and-forget：状态轮询与即焚语义都在 store 内闭环）
      if (cloudAnalysisExecutor) {
        cloudAnalysisExecutor.run(task.id).catch(() => {});
      }
      return context.json({ ok: true, status: "queued" });
    } catch (error) {
      return createErrorResponse(context, error);
    }
  });

  app.get("/v1/ai/agent/cloud/:id", async (context) => {
    try {
      const store = requireCloudAnalysisStore();
      const deviceId = getDeviceId(context, config);
      const task = store.getDecrypted(context.req.param("id"));
      if (!task || task.device_id !== deviceId) {
        throw new GatewayError("NOT_FOUND", "Task not found", 404);
      }
      context.header("Cache-Control", "no-store");
      const body = { status: task.status };
      if (task.status === "completed" && task.result) {
        // 领取不删（R1）：删除权交给客户端落地后的 ack——响应在网络回程丢失时
        // 结果不丢，冷启动恢复轮询可再次领取；未 ack 由 7 天过期兜底。
        body.result = JSON.parse(task.result);
      } else if (task.status === "failed" && task.failureReason) {
        body.failureReason = task.failureReason;
      }
      return context.json(body);
    } catch (error) {
      return createErrorResponse(context, error);
    }
  });

  // 结果领取确认（R1）：客户端已落地本地后回执，服务端销毁结果密文。
  app.post("/v1/ai/agent/cloud/:id/ack", async (context) => {
    try {
      const store = requireCloudAnalysisStore();
      const deviceId = getDeviceId(context, config);
      const task = store.get(context.req.param("id"));
      if (!task || task.device_id !== deviceId) {
        throw new GatewayError("NOT_FOUND", "Task not found", 404);
      }
      store.consumeResult(task.id);
      return context.json({ ok: true });
    } catch (error) {
      return createErrorResponse(context, error);
    }
  });

  // 设备推送令牌上报（云端分析完成通知用）：APNs token = 64 位十六进制；
  // 低频上报（启动/令牌轮换），轻限流防刷。
  app.post("/v1/ai/agent/cloud/device-token", async (context) => {
    try {
      const deviceId = getDeviceId(context, config);
      const request = await readJson(context);
      const token = typeof request.token === "string" ? request.token.trim().toLowerCase() : "";
      if (!/^[0-9a-f]{64}$/.test(token)) {
        throw new GatewayError("INVALID_REQUEST", "token must be 64 hex chars", 400);
      }
      const usage = usageStore.consume({
        deviceId,
        purpose: "device_token_report",
        minuteLimit: config.limits.deviceTokenReportsPerMinute,
        dailyLimit: config.limits.deviceTokenReportsPerDay,
      });
      if (!usage.allowed) {
        throw new GatewayError("RATE_LIMITED", "Device rate limit exceeded", 429);
      }
      deviceTokenStore.upsert(deviceId, token);
      context.header("Cache-Control", "no-store");
      return context.json({ ok: true });
    } catch (error) {
      return createErrorResponse(context, error);
    }
  });

  app.delete("/v1/ai/agent/cloud/:id", async (context) => {
    try {
      const store = requireCloudAnalysisStore();
      const deviceId = getDeviceId(context, config);
      const task = store.get(context.req.param("id"));
      if (!task || task.device_id !== deviceId) {
        throw new GatewayError("NOT_FOUND", "Task not found", 404);
      }
      store.cancel(task.id);
      return context.json({ ok: true });
    } catch (error) {
      return createErrorResponse(context, error);
    }
  });

  // Agent 遥测批量上报：iOS 端锁屏租约/执行恢复/任务终态等技术诊断事件的
  // 服务端落地。出障时远端可直接还原时间线（2026-08-30 锁屏事故：证据只在
  // 手机本地，排查靠推演）。字段与 iOS HoloAgentTelemetryEvent 一一对应，
  // 仅收白名单技术字段，不收任何用户内容。
  app.post("/v1/ai/agent/telemetry", async (context) => {
    try {
      const deviceId = getDeviceId(context, config);
      const request = await readJson(context);

      const usage = usageStore.consume({
        deviceId,
        purpose: "agent_telemetry",
        minuteLimit: config.limits.agentTelemetryUploadsPerMinute,
        dailyLimit: config.limits.agentTelemetryUploadsPerDay,
      });
      if (!usage.allowed) {
        throw new GatewayError("RATE_LIMITED", "Device rate limit exceeded", 429);
      }

      const rawEvents = Array.isArray(request.events) ? request.events : null;
      if (!rawEvents || rawEvents.length === 0) {
        throw new GatewayError("INVALID_REQUEST", "events must be a non-empty array", 400);
      }
      if (rawEvents.length > 100) {
        throw new GatewayError("INVALID_REQUEST", "at most 100 events per batch", 400);
      }

      const events = rawEvents.map(normalizeAgentTelemetryEvent);
      const inserted = agentTelemetryStore.insertBatch(deviceId, events);
      return context.json({ ok: true, accepted: inserted });
    } catch (error) {
      return createErrorResponse(context, error);
    }
  });

  return app;
}

function isUploadedFile(value) {
  return Boolean(
    value &&
    typeof value === "object" &&
    typeof value.arrayBuffer === "function" &&
    typeof value.size === "number",
  );
}

function createAsrProvider(config) {
  if (config.asrProvider) {
    return config.asrProvider;
  }

  if (config.asr.provider === "dashscope") {
    return createDashScopeAsrProvider(config.asr);
  }

  return createMockAsrProvider();
}

function createProviders(config) {
  const providers = new Map();
  providers.set("mock", createMockChatProvider());

  for (const [name, providerConfig] of Object.entries(config.providers)) {
    if (providerConfig.type === "openai-compatible") {
      providers.set(name, createOpenAICompatibleProvider(providerConfig));
    }
  }

  for (const [name, provider] of config.providerOverrides ?? []) {
    providers.set(name, provider);
  }

  return providers;
}

async function completeInsightWithRetry(complete, request) {
  const retryRequest = { ...request, responseFormat: undefined };
  let result = await complete(retryRequest);
  let failure = classifyInsightResponse(result);
  if (!failure) return result;

  result = await complete(retryRequest);
  failure = classifyInsightResponse(result);
  if (!failure) return result;
  throw new GatewayError(failure, failure, 502);
}

function classifyInsightResponse(result) {
  const choice = result?.choices?.[0];
  if (choice?.finish_reason === "length") return "TRUNCATED_MODEL_RESPONSE";
  const content = choice?.message?.content;
  if (typeof content !== "string" || content.trim() === "") return "EMPTY_MODEL_RESPONSE";
  if (!content.includes("{") || !content.includes("}")) return "INVALID_INSIGHT_JSON";
  return null;
}

function summarizeInsightResponse(result) {
  const choice = result?.choices?.[0];
  return {
    status: "success",
    finishReason: choice?.finish_reason ?? null,
    contentLength: choice?.message?.content?.length ?? 0,
    reasoningLength: choice?.message?.reasoning_content?.length ?? 0,
    usage: result?.usage ?? null,
  };
}

/// agent_loop 响应摘要：记录模型正文（content）+ finish_reason + usage，
/// 用于调试"模型每轮返回了什么 status / toolRequests / claims"。
/// 正文受 CONTENT_CAPTURE_MAX_CHARS 截断 + redactText 脱敏（在 finishAiCall 内完成）。
/// 注意：只有 HOLO_LOG_CAPTURE_CONTENT=true 时才会落盘（finishAiCall 判断 contentCaptureEnabled）。
function summarizeAgentLoopResponse(result) {
  const choice = result?.choices?.[0];
  return {
    status: "success",
    finishReason: choice?.finish_reason ?? null,
    content: choice?.message?.content ?? null,
    contentLength: choice?.message?.content?.length ?? 0,
    usage: result?.usage ?? null,
  };
}

function createConfiguredSessionService(auth) {
  if (!auth.sessionSecret) return null;
  return createHoloSessionService({
    secret: auth.sessionSecret,
    internalSubjects: auth.internalDiagnosticsAppleSubs,
    ttlSeconds: auth.sessionTtlSeconds,
    issuer: auth.sessionIssuer,
    audience: auth.sessionAudience,
  });
}

function createAdminTestChatRunner({ config, providers, logStore }) {
  return async function runAdminTestChat({ message, purpose, systemPrompt }) {
    const route = config.routes[purpose];
    if (!route) {
      throw new GatewayError("UNKNOWN_PURPOSE", `Unsupported purpose: ${purpose}`, 400);
    }

    const provider = providers.get(route.provider);
    if (!provider) {
      throw new GatewayError("MODEL_UNAVAILABLE", `Provider unavailable: ${route.provider}`, 503);
    }

    const systemContent = systemPrompt ?? "You are handling a Holo admin console test request.";
    const upstreamRequest = {
      messages: [
        { role: "system", content: systemContent },
        { role: "user", content: message },
      ],
      stream: false,
      model: route.model,
      temperature: route.temperature,
      maxTokens: route.maxTokens,
      responseFormat: null,
    };
    const logId = logStore.startAiCall({
      deviceId: "admin-console",
      purpose,
      provider: route.provider,
      model: route.model,
      stream: false,
      request: {
        messages: upstreamRequest.messages,
        responseFormat: null,
        temperature: route.temperature,
        maxTokens: route.maxTokens,
      },
    });

    try {
      const result = await provider.complete(upstreamRequest);
      logStore.finishAiCall(logId, {
        status: "success",
        response: result,
      });
      return { logId, result };
    } catch (error) {
      logStore.finishAiCall(logId, {
        status: "error",
        error: serializeError(error),
      });
      throw error;
    }
  };
}

async function readJson(context) {
  try {
    return await context.req.json();
  } catch {
    throw new GatewayError("INVALID_JSON", "Request body must be valid JSON", 400);
  }
}

function validateChatRequest(request) {
  if (!Array.isArray(request.messages) || request.messages.length === 0) {
    throw new GatewayError("INVALID_REQUEST", "messages must be a non-empty array", 400);
  }

  for (const message of request.messages) {
    if (!["system", "user", "assistant", "tool"].includes(message.role)) {
      throw new GatewayError("INVALID_REQUEST", "message role is invalid", 400);
    }

    if (typeof message.content !== "string" || message.content.length === 0) {
      throw new GatewayError("INVALID_REQUEST", "message content must be a non-empty string", 400);
    }
  }

  if (request.usageActionId !== undefined && !normalizedActionId(request.usageActionId)) {
    throw new GatewayError("INVALID_REQUEST", "usageActionId is invalid", 400);
  }
}

function rejectClientRouting(request) {
  const blockedField = CLIENT_ROUTING_FIELDS.find((field) => Object.hasOwn(request, field));
  if (blockedField) {
    throw new GatewayError(
      "INVALID_CLIENT_ROUTING",
      `Client is not allowed to set ${blockedField}`,
      400,
    );
  }
}

function getDeviceId(context, config) {
  const deviceId = context.req.header("x-holo-device-id");
  if (deviceId) {
    return deviceId;
  }

  if (config.auth.enforceAppAttest) {
    throw new GatewayError("APP_ATTEST_REQUIRED", "App Attest assertion is required", 401);
  }

  return "debug-device";
}

// 内容安全审核命中后的拦截文案（友好、不生硬）。
const MODERATION_REFUSAL_MESSAGE = "抱歉，你的问题我暂时无法回应。换个话题吧。";

// message.content 可能是字符串，也可能是 OpenAI 多模态数组（[{type:"text",text}]）。
function extractMessageText(content) {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .map((part) => (typeof part === "string" ? part : part?.text ?? ""))
      .join("");
  }
  return "";
}

function extractLastUserText(messages) {
  const message = messages.findLast((item) => item.role === "user");
  return extractMessageText(message?.content);
}

// 非流式拦截响应：标准 chat completion 结构，finish_reason 标记为 content_filter。
function moderationRefusalCompletion() {
  return {
    choices: [
      {
        index: 0,
        message: { role: "assistant", content: MODERATION_REFUSAL_MESSAGE },
        finish_reason: "content_filter",
      },
    ],
    moderation_blocked: true,
  };
}

// 流式拦截响应：单 chunk（拒绝文案）+ [DONE]，响应头与 streamChat 保持一致。
function streamModerationBlocked(options = {}) {
  const encoder = new TextEncoder();
  const chunk = {
    choices: [
      {
        index: 0,
        delta: { role: "assistant", content: MODERATION_REFUSAL_MESSAGE },
        finish_reason: "content_filter",
      },
    ],
    moderation_blocked: true,
  };
  const stream = new ReadableStream({
    start(controller) {
      controller.enqueue(encoder.encode(`data: ${JSON.stringify(chunk)}\n\n`));
      controller.enqueue(encoder.encode("data: [DONE]\n\n"));
      controller.close();
    },
  });
  return new Response(stream, {
    headers: {
      "cache-control": "no-cache",
      "connection": "keep-alive",
      "content-type": "text/event-stream; charset=UTF-8",
      ...(options.requestId ? { "x-holo-request-id": options.requestId } : {}),
      ...(options.quotaType ? { "x-holo-quota-type": options.quotaType } : {}),
    },
  });
}

function streamChat(context, provider, request, options = {}) {
  const stream = new ReadableStream({
    async start(controller) {
      const encoder = new TextEncoder();
      let capturedText = "";

      try {
        for await (const chunk of provider.stream(request)) {
          if (typeof chunk === "string") {
            controller.enqueue(encoder.encode(chunk));
            capturedText = appendCapturedText(capturedText, chunk, options.logStore?.maxDetailChars);
          } else {
            controller.enqueue(encoder.encode(`data: ${JSON.stringify(chunk)}\n\n`));
            capturedText = appendCapturedText(
              capturedText,
              extractStreamChunkText(chunk),
              options.logStore?.maxDetailChars,
            );
          }
        }
        if (!provider.passesThroughSSE) {
          controller.enqueue(encoder.encode("data: [DONE]\n\n"));
        }
        options.logStore?.finishAiCall(options.logId, {
          status: "success",
          response: {
            text: capturedText,
          },
        });
        options.onSuccess?.();
        controller.close();
      } catch (error) {
        const code = error instanceof GatewayError ? error.code : "UPSTREAM_ERROR";
        controller.enqueue(encoder.encode(`event: error\ndata: ${JSON.stringify({ code, message: publicMessage(code) })}\n\n`));
        options.logStore?.finishAiCall(options.logId, {
          status: "error",
          response: capturedText ? { text: capturedText } : null,
          error: serializeError(error),
        });
        options.onFailure?.();
        controller.close();
      }
    },
  });

  return new Response(stream, {
    headers: {
      "cache-control": "no-cache",
      "connection": "keep-alive",
      "content-type": "text/event-stream; charset=UTF-8",
      ...(options.requestId ? { "x-holo-request-id": options.requestId } : {}),
      ...(options.quotaType ? { "x-holo-quota-type": options.quotaType } : {}),
    },
  });
}

function buildSubscriptionStatus(entitlement, quotaStore) {
  const quotas = Object.fromEntries(
    Object.values(QUOTA_TYPES).map((quotaType) => [
      quotaType,
      quotaStore.peek({
        subjectId: entitlement.usageSubjectId,
        tier: entitlement.tier,
        quotaType,
      }),
    ]),
  );
  return {
    tier: entitlement.tier,
    isPlusActive: entitlement.isPlusActive,
    productId: entitlement.productId ?? null,
    expiresAt: entitlement.expiresAt ?? null,
    source: entitlement.source,
    acceptanceMode: entitlement.acceptanceMode,
    products: {
      plusMonthly: HOLO_PLUS_PRODUCT_IDS.monthly,
      plusYearly: HOLO_PLUS_PRODUCT_IDS.yearly,
    },
    quotas,
  };
}

function quotaTypeForPurpose(purpose) {
  // chat/analysis 都是单轮对话（聊天页分析模式成本与闲聊相同），共用对话池；
  // agent_loop 是多轮工具循环（单次 15~25s、多次上游调用），成本高一个量级，独立成池。
  if (purpose === "chat" || purpose === "analysis") return QUOTA_TYPES.chat;
  if (purpose === "agent_loop") return QUOTA_TYPES.deepAnalysis;
  if (purpose === "weekly_plan_generation") return QUOTA_TYPES.lifePlan;
  if (purpose === "finance_action_parser") return QUOTA_TYPES.naturalLanguageFinance;
  // 账单导入的 AI 列映射/科目匹配与自然语言记账同属财务语义池；
  // Plus 前置由客户端在首次 AI 调用前把守，此处只兜量（B3：不开无限量桶）。
  if (purpose === "bill_column_mapping" || purpose === "bill_categorization") return QUOTA_TYPES.naturalLanguageFinance;
  if (purpose === "task_action_parser") return QUOTA_TYPES.naturalLanguageTask;
  if (purpose === "insight") return QUOTA_TYPES.memoryInsight;
  return null;
}

/** 与 iOS HoloAgentEventName 一一对应；表驱动收口，端点外不得扩展。 */
const AGENT_TELEMETRY_EVENT_NAMES = new Set([
  "agent_job_created",
  "agent_execution_acquired",
  "agent_execution_attached",
  "agent_execution_stale_rejected",
  "agent_checkpoint_committed",
  "agent_waiting_for_condition",
  "agent_execution_expired",
  "agent_resume_started",
  "agent_resume_stalled",
  "agent_step_idempotency_hit",
  "agent_result_reconciled",
  "agent_job_completed",
  "agent_job_failed",
  "agent_job_cancelled",
  "agent_lease_changed",
]);

/** 遥测事件字段白名单与归一：非法 name/缺 id 拒绝，超长字符串截断，数字非法置空。 */
function normalizeAgentTelemetryEvent(raw) {
  if (!raw || typeof raw !== "object") {
    throw new GatewayError("INVALID_REQUEST", "event must be an object", 400);
  }
  const id = typeof raw.id === "string" ? raw.id.trim() : "";
  if (!id || id.length > 64) {
    throw new GatewayError("INVALID_REQUEST", "event.id must be 1-64 chars", 400);
  }
  if (!AGENT_TELEMETRY_EVENT_NAMES.has(raw.name)) {
    throw new GatewayError("INVALID_REQUEST", `unknown event name: ${String(raw.name).slice(0, 40)}`, 400);
  }
  const timestampMs = Number(raw.timestampMs);
  if (!Number.isFinite(timestampMs)) {
    throw new GatewayError("INVALID_REQUEST", "event.timestampMs must be a finite number", 400);
  }
  const shortString = (value) => (
    typeof value === "string" && value.length > 0 ? value.slice(0, 64) : null
  );
  const optionalInt = (value) => (
    Number.isFinite(value) ? Math.trunc(value) : null
  );
  return {
    id,
    name: raw.name,
    timestampMs: Math.trunc(timestampMs),
    jobID: shortString(raw.jobID),
    jobType: shortString(raw.jobType),
    trigger: shortString(raw.trigger),
    state: shortString(raw.state),
    waitReason: shortString(raw.waitReason),
    generation: optionalInt(raw.generation),
    checkpointRevision: optionalInt(raw.checkpointRevision),
    leaseKind: shortString(raw.leaseKind),
    round: optionalInt(raw.round),
    durationMilliseconds: optionalInt(raw.durationMilliseconds),
    errorCode: shortString(raw.errorCode),
    requestID: shortString(raw.requestID),
    promptRevision: optionalInt(raw.promptRevision),
    agentProtocolVersion: optionalInt(raw.agentProtocolVersion),
    toolSchemaVersion: optionalInt(raw.toolSchemaVersion),
    contractViolationCount: optionalInt(raw.contractViolationCount),
    contractRepairCount: optionalInt(raw.contractRepairCount),
  };
}

function resolveQuotaActionId(request, purpose) {
  const explicit = normalizedActionId(request.usageActionId);
  if (explicit) return explicit;
  if (purpose === "agent_loop") {
    const runId = normalizedActionId(request.runId);
    if (runId) return runId;
  }
  return randomUUID();
}

function normalizedActionId(value) {
  if (typeof value !== "string") return null;
  const normalized = value.trim();
  if (!normalized || normalized.length > 128) return null;
  return normalized;
}

function quotaExceededError(snapshot) {
  return new GatewayError("QUOTA_EXCEEDED", "Membership quota exceeded", 429, {
    quotaType: snapshot.quotaType,
    tier: snapshot.tier,
    limit: snapshot.limit,
    used: snapshot.used,
    remaining: snapshot.remaining,
    resetAt: snapshot.resetAt,
    period: snapshot.period,
    upgradeAvailable: snapshot.tier !== "plus",
  });
}

function commitQuota(store, reservation) {
  if (reservation) store.commit(reservation);
}

function releaseQuota(store, reservation) {
  if (reservation) store.release(reservation);
}

function validateAsrDuration(tier, durationSeconds) {
  if (durationSeconds === null) return;
  const maxSeconds = getQuotaRule(tier, QUOTA_TYPES.asr).maxSeconds;
  // 容差：客户端录音倒计时按 200ms 轮询，到点自动停止时实际录音文件
  // 常会比 maxSeconds 多出零点几秒。给 1 秒容差，避免 60.x 秒的抖动
  // 被判超时——这对用户是体验上限，不是物理硬约束。
  if (durationSeconds <= maxSeconds + 1) return;
  throw new GatewayError("ASR_DURATION_EXCEEDED", "Audio duration exceeded", 429, {
    quotaType: QUOTA_TYPES.asr,
    tier: tier === "plus" ? "plus" : "free",
    maxSeconds,
    actualSeconds: durationSeconds,
    upgradeAvailable: tier !== "plus",
  });
}

function resolveAudioDurationSeconds(rawDuration, audioBuffer) {
  if (rawDuration !== undefined) {
    const value = Number(rawDuration);
    if (Number.isFinite(value) && value >= 0) return value;
  }
  return wavDurationSeconds(audioBuffer);
}

function wavDurationSeconds(audioBuffer) {
  const bytes = new Uint8Array(audioBuffer);
  if (bytes.length < 44 || ascii(bytes, 0, 4) !== "RIFF" || ascii(bytes, 8, 4) !== "WAVE") {
    return null;
  }
  const view = new DataView(audioBuffer);
  let offset = 12;
  let byteRate = null;
  let dataSize = null;
  while (offset + 8 <= bytes.length) {
    const chunkId = ascii(bytes, offset, 4);
    const chunkSize = view.getUint32(offset + 4, true);
    if (chunkId === "fmt " && chunkSize >= 16 && offset + 16 <= bytes.length) {
      byteRate = view.getUint32(offset + 12, true);
    } else if (chunkId === "data") {
      dataSize = Math.min(chunkSize, bytes.length - offset - 8);
    }
    offset += 8 + chunkSize + (chunkSize % 2);
  }
  return byteRate && dataSize !== null ? dataSize / byteRate : null;
}

function ascii(bytes, offset, length) {
  return String.fromCharCode(...bytes.slice(offset, offset + length));
}

function appendCapturedText(current, next, maxChars = 20_000) {
  if (!next) {
    return current;
  }

  return truncateText(`${current}${next}`, maxChars);
}

function resolveChatRequestLimits(config, route) {
  const routeLimits = route?.requestLimits ?? {};
  return {
    perMinute: Number(routeLimits.perMinute ?? config.limits.chatRequestsPerMinute),
    perDay: Number(routeLimits.perDay ?? config.limits.chatRequestsPerDay),
  };
}

function extractStreamChunkText(chunk) {
  return chunk?.choices
    ?.map((choice) => choice.delta?.content ?? choice.message?.content ?? "")
    .join("") ?? "";
}

function summarizeMessages(messages) {
  if (!Array.isArray(messages)) return "";
  return messages
    .map(m => {
      const content = m.content ?? "";
      return content.length > 120 ? content.substring(0, 120) + "…" : content;
    })
    .filter(Boolean)
    .join(" | ")
    .substring(0, 300);
}

function serializeError(error) {
  if (error instanceof GatewayError) {
    return {
      code: error.code,
      message: error.message,
      status: error.status,
    };
  }

  return {
    code: "UPSTREAM_ERROR",
    message: error instanceof Error ? error.message : "Unknown error",
  };
}

/**
 * 解析 agent_loop 的 step 幂等身份。
 * - 三字段（runId/stepId/requestHash）齐全 → 启用幂等
 * - 三字段全缺 → 旧客户端，返回 null（走原路径，无幂等）
 * - 部分缺失 → 协议错误，拒绝请求
 */
function resolveAgentStepIdentity(isAgentLoop, request) {
  if (!isAgentLoop) return null;

  const hasRunId = typeof request.runId === "string" && request.runId.length > 0;
  const hasStepId = typeof request.stepId === "string" && request.stepId.length > 0;
  const hasRequestHash = typeof request.requestHash === "string" && request.requestHash.length > 0;

  if (!hasRunId && !hasStepId && !hasRequestHash) return null;
  if (hasRunId && hasStepId && hasRequestHash) {
    return { runId: request.runId, stepId: request.stepId, requestHash: request.requestHash };
  }
  throw new GatewayError(
    "INVALID_REQUEST",
    "runId, stepId and requestHash must be provided together",
    400,
  );
}

/**
 * Agent step 结构化事件：只写技术 identity、状态和 token 计数。
 * 禁止传入 messages、requestHash、模型响应或用户业务内容。
 */
function logAgentStepEvent(event, identity, fields = {}) {
  console.info(JSON.stringify({
    category: "holo_agent",
    event,
    timestamp: new Date().toISOString(),
    runId: identity.runId,
    stepId: identity.stepId,
    ...fields,
  }));
}

/**
 * step 幂等门控：决定本次请求是直接返回缓存/错误，还是获得 provider 调用权。
 * 并发下 createProcessing/reacquireProcessing 可能因唯一约束或状态竞争失败，
 * 此时重读记录再判定；多次竞争未决兜底按 in_progress 处理（客户端退避重试）。
 */
function acquireAgentStep(store, identity, ttlSeconds) {
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const existing = store.get(identity.runId, identity.stepId);
    if (!existing) {
      if (store.createProcessing(identity.runId, identity.stepId, identity.requestHash, ttlSeconds)) {
        return { type: "acquired" };
      }
      continue;
    }
    if (existing.requestHash !== identity.requestHash) {
      return { type: "conflict" };
    }
    if (existing.status === "completed") {
      return { type: "completed", record: existing };
    }
    if (existing.status === "processing") {
      return { type: "in_progress" };
    }
    if (existing.status === "failed_final") {
      return { type: "failed_final", record: existing };
    }
    // failed_retryable：受控重试，原子转回 processing
    if (store.reacquireProcessing(identity.runId, identity.stepId, identity.requestHash, ttlSeconds)) {
      return { type: "acquired" };
    }
  }
  return { type: "in_progress" };
}

/** 5xx/429 与非 GatewayError 视为可重试；其余 4xx 为终态失败 */
function isRetryableAgentStepError(error) {
  if (error instanceof GatewayError) {
    return error.code === "CLIENT_ABORTED" || error.status >= 500 || error.status === 429;
  }
  return true;
}

/** provider 调用失败后落幂等状态；存储失败不掩盖原始错误 */
function recordAgentStepFailure(store, identity, error) {
  try {
    store.markFailed(identity.runId, identity.stepId, {
      retryable: isRetryableAgentStepError(error),
      errorCode: error instanceof GatewayError ? error.code : "UPSTREAM_ERROR",
      errorStatus: error instanceof GatewayError ? error.status : 500,
    });
  } catch (storeError) {
    console.error(
      "[holo-backend] agent step 幂等状态写入失败:",
      storeError?.message ?? storeError,
    );
  }
}

/** 启动期 queued 孤儿扫描：进程重启后未执行的云端分析任务重新拉起 */
function resumeQueuedCloudAnalysisTasks(store, executor, limit = 50) {
  try {
    // R2：进程重启后执行中断的 running 任务先重置回队列（否则永久卡死无人接管）
    const orphaned = store.requeueOrphanRunning?.() ?? 0;
    if (orphaned > 0) {
      console.log(`[holo-backend] 云端分析重启恢复：重置 ${orphaned} 个中断 running 任务`);
    }
    const db = store.listQueued?.(limit);
    if (!db) return;
    for (const taskId of db) {
      executor.run(taskId).catch(() => {});
    }
    if (db.length > 0) {
      console.log(`[holo-backend] 云端分析启动恢复 ${db.length} 个 queued 任务`);
    }
  } catch (error) {
    console.error("[holo-backend] 云端分析启动恢复失败:", error?.message ?? error);
  }
}

/** 后台 TTL 清理；unref 避免阻止进程退出，返回可关闭句柄 */
function startAgentStepCleanupTimer(store, intervalMs) {
  if (!Number.isFinite(intervalMs) || intervalMs <= 0) {
    return { stop() {} };
  }
  const timer = setInterval(() => {
    try {
      const purged = store.purgeExpired(Date.now());
      if (purged > 0) {
        console.log(`[holo-backend] agent step 幂等记录清理 ${purged} 条`);
      }
    } catch (error) {
      console.error("[holo-backend] agent step 幂等清理失败:", error?.message ?? error);
    }
  }, intervalMs);
  timer.unref?.();
  return {
    stop() {
      clearInterval(timer);
    },
  };
}
