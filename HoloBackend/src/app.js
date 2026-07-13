import { Hono } from "hono";
import { randomBytes } from "node:crypto";

import { createErrorResponse, GatewayError, publicMessage } from "./errors.js";
import { createInMemoryUsageStore } from "./usage/inMemoryUsageStore.js";
import { createSqliteUsageStore } from "./usage/sqliteUsageStore.js";
import { createMockChatProvider } from "./providers/mockChatProvider.js";
import { createOpenAICompatibleProvider } from "./providers/openAICompatibleProvider.js";
import { createMockAsrProvider } from "./providers/mockAsrProvider.js";
import { createDashScopeAsrProvider } from "./providers/dashScopeAsrProvider.js";
import { getFinanceCategoryCatalog } from "./catalog/financeCategoryCatalog.js";
import { validateAgentLoopContent } from "./agentResponseValidator.js";
import { getPrompt, listPrompts, listPromptMetadata, setDatabase } from "./prompts/promptRegistry.js";
import { loadConfig } from "./config.js";
import { createAdminLogStore, truncateText } from "./admin/adminLogStore.js";
import { registerAdminRoutes } from "./admin/adminRoutes.js";
import { createRequestLogger } from "./middleware/requestLogger.js";
import { createDatabase } from "./db/database.js";
import { createAppleIdentityVerifier } from "./auth/appleIdentityVerifier.js";
import { createHoloSessionService } from "./auth/holoSession.js";
import { requireInternalDiagnostics } from "./auth/internalDiagnosticsAuth.js";
import { injectServerPrompt } from "./prompts/serverPromptPolicy.js";

const CLIENT_ROUTING_FIELDS = ["baseURL", "baseUrl", "apiKey", "provider", "model"];

function buildAdminReleaseStatus(config) {
  return {
    ok: true,
    service: "holo-ai-gateway",
    generatedAt: new Date().toISOString(),
    release: {
      commit: process.env.HOLO_RELEASE_COMMIT ?? null,
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
  };
}

function buildPublicReleaseStatus() {
  return {
    ok: true,
    service: "holo-ai-gateway",
    release: {
      commit: process.env.HOLO_RELEASE_COMMIT ?? null,
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

  // SQLite 数据库（可选，测试时可以不传）
  const database = config.database ?? createDatabase({ dbPath: config.dbPath });

  // 注入数据库到 Prompt 管理
  setDatabase(database.db);

  const usageStore = config.usageStore ?? createSqliteUsageStore(database.db);
  const adminLogStore =
    config.adminLogStore ??
    createAdminLogStore({
      maxEntries: config.admin.logMaxEntries,
      maxDetailChars: config.admin.logDetailMaxChars,
      db: database.db,
      contentCaptureEnabled: config.contentCaptureEnabled,
    });
  const providers = createProviders(config);
  const asrProvider = createAsrProvider(config);
  const captureAiCallLogs = config.aiCallLogs.enabled;
  const appleIdentityVerifier = config.appleIdentityVerifier ?? createAppleIdentityVerifier({
    clientIds: config.auth.appleClientIds,
  });
  const holoSessionService = config.holoSessionService ?? createConfiguredSessionService(config.auth);

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
    runTestChat: runAdminTestChat,
    getReleaseStatus: () => buildAdminReleaseStatus(config),
    db: database.db,
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

  app.post("/v1/ai/chat/completions", async (context) => {
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

      const serverPrompt = injectServerPrompt(purpose, request.messages);
      const upstreamRequest = {
        purpose,
        messages: serverPrompt.messages,
        stream: request.stream === true,
        model: route.model,
        temperature: route.temperature,
        maxTokens: route.maxTokens,
        responseFormat: request.response_format,
        clientSignal: context.req.raw.signal,
      };
      const isAgentLoop = purpose === "agent_loop";
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
                  summary: summarizeMessages(upstreamRequest.messages),
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

      if (upstreamRequest.stream) {
        return streamChat(context, provider, upstreamRequest, {
          logStore: logId ? adminLogStore : null,
          logId,
          requestId: logId,
        });
      }

      try {
        const result = await provider.complete(upstreamRequest);
        if (purpose === "agent_loop") {
          const agentContent = result?.choices?.[0]?.message?.content;
          const agentValidation = validateAgentLoopContent(agentContent ?? "");
          if (!agentValidation.valid) {
            throw new GatewayError("INVALID_AGENT_JSON", agentValidation.error, 502);
          }
          result.choices[0].message.content = agentValidation.content;
        }
        if (logId) {
          adminLogStore.finishAiCall(logId, {
            status: "success",
            response: isAgentLoop
              ? { status: "success", usage: result?.usage ?? null }
              : result,
          });
        }
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
      return createErrorResponse(context, error);
    }
  });

  app.post("/v1/asr/transcriptions", async (context) => {
    try {
      const deviceId = getDeviceId(context, config);
      const usage = usageStore.consume({
        deviceId,
        purpose: "asr",
        minuteLimit: config.limits.asrRequestsPerMinute,
        dailyLimit: config.limits.asrRequestsPerDay,
      });
      if (!usage.allowed) {
        throw new GatewayError("RATE_LIMITED", "Device rate limit exceeded", 429);
      }

      const formData = await context.req.formData();
      const audio = formData.get("audio");
      if (!isUploadedFile(audio)) {
        throw new GatewayError("INVALID_REQUEST", "audio file is required", 400);
      }

      if (audio.size > config.limits.asrMaxBytes) {
        throw new GatewayError("AUDIO_TOO_LARGE", "Audio file is too large", 413);
      }

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
          audio: await audio.arrayBuffer(),
          fileName: audio.name,
          mimeType: audio.type,
          locale: formData.get("locale")?.toString() ?? null,
        });
        if (logId) {
          const transcriptText = result.text ?? JSON.stringify(result);
          adminLogStore.finishAiCall(logId, {
            status: "success",
            response: result,
            asrResultLength: transcriptText.length,
          });
        }
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

  return providers;
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
        controller.close();
      } catch (error) {
        const code = error instanceof GatewayError ? error.code : "UPSTREAM_ERROR";
        controller.enqueue(encoder.encode(`event: error\ndata: ${JSON.stringify({ code, message: publicMessage(code) })}\n\n`));
        options.logStore?.finishAiCall(options.logId, {
          status: "error",
          response: capturedText ? { text: capturedText } : null,
          error: serializeError(error),
        });
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
    },
  });
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
