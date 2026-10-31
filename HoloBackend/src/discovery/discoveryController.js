import { GatewayError, createErrorResponse } from "../errors.js";
import { backgroundSubject } from "../usage/backgroundCostGuard.js";
import { injectServerPrompt, promptTypeForPurpose } from "../prompts/serverPromptPolicy.js";
import { getPrompt } from "../prompts/promptRegistry.js";
import { canonicalSha256 } from "./discoveryCanonicalJson.js";
import { validateDiscoveryOutput } from "./discoveryOutputSchema.js";

/**
 * 「一个发现」专用控制器与路由（实施包 03 §3）。
 *
 * ⚠️ 跨端契约纪律：本文件每个 context.json(...) 返回体是 iOS 解码模型的唯一真源
 * （Holo/Services/AI/Discovery/DiscoveryClient.swift）。改任何返回体的字段/类型/嵌套结构，
 * 必须同一批同步 iOS 模型与 HoloTests/.../DiscoveryContractTests.swift 的字面量并跑绿——
 * 否则后端 200、客户端解码失败（2026-10-28 grant 事故实录）。规范：
 * docs/standards/跨端接口契约规范.md
 *
 * 八个端点 + 通用 chat 防旁路。所有阶段端点每步复核（03 §5）：
 * 设备会话 → 主体导出（服务端派生，body 不信任）→ run 归属（subject+device）
 * → control/scope 代数仍匹配 → 日批次（run 行即预留）→ 租约未过期 → token 有效。
 *
 * 模型调用：复用既有 provider 体系（已由 app.js 单点 wrapProviders 计入后台预算，
 * 此处只建 AsyncLocalStorage 主体域，不 reserveDirect——避免 wrap 两遍翻倍），
 * 上游响应先过 ai-output.schema.json 代码化严格校验，再按 purpose 记账。
 * 请求/响应正文不进日志（purpose 已入 adminLogStore metadata-only 强制清单）。
 */

export const DISCOVERY_PURPOSES = Object.freeze({
  candidates: "discovery_candidate_v1",
  verify: "discovery_verify_v1",
});

export function registerDiscoveryRoutes(app, deps) {
  const {
    config,
    providers,
    getDeviceId,
    entitlementStore,
    usageStore,
    adminLogStore,
    getSessionId,
    controlStore,
    runStore,
    backgroundCostGuard,
    captureAiCallLogs,
  } = deps;

  const requireEnabled = () => {
    // kill switch（T49）：HOLO_DISCOVERY_ENABLED=false 时全端点 503，停一切新调用；
    // capabilities 仍返回 200 + enabled=false，让客户端解释「未开放」而非伪装发现。
    if (!config.discovery?.enabled) {
      throw new GatewayError("DISCOVERY_DISABLED", "Discovery is not enabled", 503);
    }
  };

  const resolveIdentity = async (context) => {
    const deviceId = await getDeviceId(context, config);
    const entitlement = entitlementStore.get(deviceId);
    return { deviceId, subject: backgroundSubject(deviceId, entitlement) };
  };

  const readJson = async (context) => {
    try {
      return await context.req.json();
    } catch {
      throw new GatewayError("INVALID_JSON", "Request body must be valid JSON", 400);
    }
  };

  const assertBodySize = (context) => {
    const contentLength = Number(context.req.header("content-length") ?? 0);
    const max = config.discovery.maxBodyBytes;
    if (contentLength > max) {
      throw new GatewayError("DISCOVERY_INPUT_TOO_LARGE", `Request body exceeds ${max} bytes`, 413);
    }
  };

  const consumeRateLimit = (context, deviceId, purpose) => {
    const route = config.routes[purpose];
    const requestLimits = route?.requestLimits ?? {};
    const usage = usageStore.consume({
      deviceId,
      purpose,
      minuteLimit: Number(requestLimits.perMinute ?? config.limits.chatRequestsPerMinute),
      dailyLimit: Number(requestLimits.perDay ?? config.limits.chatRequestsPerDay),
    });
    if (!usage.allowed) {
      throw new GatewayError("RATE_LIMITED", "Device rate limit exceeded", 429, { reason: usage.reason });
    }
  };

  const controlSnapshot = (context, subject) => {
    const control = controlStore.get(subject);
    context.header("Cache-Control", "no-store");
    return control;
  };

  // ===== 能力发现 =====
  app.get("/v1/discovery/capabilities", async (context) => {
    try {
      // 已鉴权设备才给能力快照（03 §3.1）；强制设备会话模式下未鉴权不可探测
      await resolveIdentity(context);
      const enabled = config.discovery?.enabled === true;
      context.header("Cache-Control", "no-store");
      return context.json({
        protocolVersion: 1,
        enabled,
        policyVersion: config.discovery.policyVersion,
        allowedDomains: config.discovery.allowedDomains,
        budget: {
          runsPerDay: config.discovery.runsPerDay,
          candidateMaxTokens: config.routes[DISCOVERY_PURPOSES.candidates]?.maxTokens ?? null,
          verifyMaxTokens: config.routes[DISCOVERY_PURPOSES.verify]?.maxTokens ?? null,
          inputBudgetTokens: config.discovery.inputBudgetTokens,
        },
      });
    } catch (error) {
      return createErrorResponse(context, error);
    }
  });

  // ===== 控制查询 =====
  app.get("/v1/discovery/control", async (context) => {
    try {
      requireEnabled();
      const { subject } = await resolveIdentity(context);
      const control = controlSnapshot(context, subject);
      return context.json({
        enabled: control.enabled,
        revision: control.revision,
        ownerDeviceId: control.ownerDeviceId,
        scopeRevision: control.scopeRevision,
        allowedDomains: control.allowedDomains,
        consentDocVersion: control.consentDocVersion,
      });
    } catch (error) {
      return createErrorResponse(context, error);
    }
  });

  // ===== 开启（CAS + 单 owner 接管）=====
  app.post("/v1/discovery/control/enable", async (context) => {
    try {
      requireEnabled();
      assertBodySize(context);
      const { deviceId, subject } = await resolveIdentity(context);
      const body = await readJson(context);
      requireFields(body, ["expectedRevision", "requestID"]);
      consumeRateLimit(context, deviceId, "discovery_control");
      const { control, grant, replayed } = controlStore.enable({
        subject,
        deviceId,
        expectedRevision: requireInt(body.expectedRevision, "expectedRevision"),
        allowedDomains: body.allowedDomains,
        consentDocVersion: optionalString(body.consentDocVersion, 64),
        confirmTakeover: body.confirmTakeover === true,
        requestId: requireId(body.requestID, "requestID"),
      });
      context.header("Cache-Control", "no-store");
      return context.json({
        enabled: control.enabled,
        revision: control.revision,
        scopeRevision: control.scopeRevision,
        allowedDomains: control.allowedDomains,
        ownerDeviceId: control.ownerDeviceId,
        grant,
        replayed,
      });
    } catch (error) {
      return createErrorResponse(context, error);
    }
  });

  // ===== 关闭（任一同主体设备；保守覆盖；幂等）=====
  app.post("/v1/discovery/control/disable", async (context) => {
    try {
      requireEnabled();
      assertBodySize(context);
      const { deviceId, subject } = await resolveIdentity(context);
      const body = await readJson(context);
      requireFields(body, ["requestID"]);
      consumeRateLimit(context, deviceId, "discovery_control");
      const { control, replayed } = controlStore.disable({
        subject,
        reason: optionalString(body.reason, 64),
        requestId: requireId(body.requestID, "requestID"),
      });
      context.header("Cache-Control", "no-store");
      return context.json({
        enabled: control.enabled,
        revision: control.revision,
        scopeRevision: control.scopeRevision,
        replayed,
      });
    } catch (error) {
      return createErrorResponse(context, error);
    }
  });

  // ===== 范围更新（CAS 递增 scopeRevision+revision）=====
  app.post("/v1/discovery/control/scope", async (context) => {
    try {
      requireEnabled();
      assertBodySize(context);
      const { deviceId, subject } = await resolveIdentity(context);
      const body = await readJson(context);
      requireFields(body, ["expectedRevision", "requestID"]);
      consumeRateLimit(context, deviceId, "discovery_control");
      const { control, replayed } = controlStore.updateScope({
        subject,
        deviceId,
        expectedRevision: requireInt(body.expectedRevision, "expectedRevision"),
        allowedDomains: body.allowedDomains,
        consentDocVersion: optionalString(body.consentDocVersion, 64),
        requestId: requireId(body.requestID, "requestID"),
      });
      context.header("Cache-Control", "no-store");
      return context.json({
        enabled: control.enabled,
        revision: control.revision,
        scopeRevision: control.scopeRevision,
        allowedDomains: control.allowedDomains,
        replayed,
      });
    } catch (error) {
      return createErrorResponse(context, error);
    }
  });

  // ===== 创建 run（当日批次预留 + run token + 租约）=====
  app.post("/v1/discovery/runs", async (context) => {
    try {
      requireEnabled();
      assertBodySize(context);
      const { deviceId, subject } = await resolveIdentity(context);
      const body = await readJson(context);
      requireFields(body, ["runID"]);
      consumeRateLimit(context, deviceId, "discovery_control");
      const control = controlStore.get(subject);
      if (!control.enabled) {
        throw new GatewayError("DISCOVERY_CONTROL_DISABLED", "Discovery is not enabled", 409);
      }
      // 单 owner：只有 owner 设备能准备发现（03 §3.2）
      if (control.ownerDeviceId && control.ownerDeviceId !== deviceId) {
        throw new GatewayError("DISCOVERY_RUN_NOT_OWNER", "Only the owner device prepares discoveries", 409);
      }
      const runId = requireId(body.runID, "runID");
      const requestHash = stageRequestHash("run_create", runId, {
        sourceManifestDigest: body.sourceManifestDigest ?? null,
      });
      const { run, runToken, replayed } = runStore.createRun({
        runId,
        subject,
        deviceId,
        control,
        sourceManifestDigest: optionalString(body.sourceManifestDigest, 128),
        requestId: optionalString(body.requestID, 128),
        requestHash,
        idempotency: ({ requestId, requestHash: hash, record }) => (
          record
            ? controlStore.recordRequest({
                requestId, subject, kind: "run_create", requestHash: hash,
                status: record.status, resultMeta: record.resultMeta,
              })
            : controlStore.replayOrThrow({ requestId, subject, kind: "run_create", requestHash: hash })
        ),
      });
      context.header("Cache-Control", "no-store");
      return context.json({
        runID: run.run_id,
        runToken,
        status: run.status,
        controlRevision: run.control_revision,
        scopeRevision: run.scope_revision,
        dayKey: run.day_key,
        leaseExpiresAt: run.lease_expires_at,
        leaseSeconds: config.discovery.leaseSeconds,
        stageBudget: { candidates: 1, verify: 1 },
        replayed,
      });
    } catch (error) {
      return createErrorResponse(context, error);
    }
  });

  // ===== 阶段一：候选生成 =====
  app.post("/v1/discovery/runs/:id/candidates", async (context) => {
    try {
      requireEnabled();
      assertBodySize(context);
      const { deviceId, subject } = await resolveIdentity(context);
      const body = await readJson(context);
      const result = await runStage({
        context, subject, deviceId,
        runId: context.req.param("id"),
        stage: "candidates",
        purpose: DISCOVERY_PURPOSES.candidates,
        body,
      });
      context.header("Cache-Control", "no-store");
      return context.json(result);
    } catch (error) {
      return createErrorResponse(context, error);
    }
  });

  // ===== 阶段二：独立核验（必须在 candidates 成功后；候选包 hash 双端一致）=====
  app.post("/v1/discovery/runs/:id/verify", async (context) => {
    try {
      requireEnabled();
      assertBodySize(context);
      const { deviceId, subject } = await resolveIdentity(context);
      const body = await readJson(context);
      requireFields(body, ["candidates", "candidatesHash"]);
      if (!Array.isArray(body.candidates)) {
        throw new GatewayError("INVALID_REQUEST", "candidates must be an array", 400);
      }
      // 先验证客户端提交包自身自洽，再与服务端规范化候选响应比对（T34）
      const submittedHash = canonicalSha256(body.candidates);
      if (submittedHash !== body.candidatesHash) {
        throw new GatewayError("DISCOVERY_HASH_MISMATCH", "candidatesHash does not match submitted candidates", 400);
      }
      const result = await runStage({
        context, subject, deviceId,
        runId: context.req.param("id"),
        stage: "verify",
        purpose: DISCOVERY_PURPOSES.verify,
        body,
        verifyInput: { candidates: body.candidates, submittedHash },
      });
      context.header("Cache-Control", "no-store");
      return context.json(result);
    } catch (error) {
      return createErrorResponse(context, error);
    }
  });

  // ===== 取消（本 run 不再接受新阶段；不承诺第三方从未处理）=====
  app.post("/v1/discovery/runs/:id/cancel", async (context) => {
    try {
      requireEnabled();
      assertBodySize(context);
      const { deviceId, subject } = await resolveIdentity(context);
      const body = await readJson(context);
      consumeRateLimit(context, deviceId, "discovery_control");
      const { run, alreadyClosed } = runStore.cancel({ runId: context.req.param("id"), subject, deviceId });
      context.header("Cache-Control", "no-store");
      return context.json({
        runID: context.req.param("id"),
        status: run?.status ?? "cancelled",
        alreadyClosed,
      });
    } catch (error) {
      return createErrorResponse(context, error);
    }
  });

  // ===== 阶段共享编排 =====
  async function runStage({ context, subject, deviceId, runId, stage, purpose, body, verifyInput }) {
    requireFields(body, ["data"]);
    if (!body.data || typeof body.data !== "object" || Array.isArray(body.data)) {
      throw new GatewayError("INVALID_REQUEST", "data must be an object", 400);
    }
    const control = controlStore.get(subject);
    const run = runStore.authorizeStage({ runId, subject, deviceId, runToken: body.runToken, stage });
    runStore.assertControlCurrent(run, control);
    consumeRateLimit(context, deviceId, purpose);

    if (body.data.runID !== undefined && body.data.runID !== runId) {
      throw new GatewayError("INVALID_REQUEST", "data.runID does not match the run", 400);
    }

    const dataHash = canonicalSha256(body.data);
    const requestHash = stageRequestHash(stage, runId, { dataHash });

    // 幂等键冲突检测（T16：同 requestId 不同 body → 409）；重放不从这里恢复结果——
    // 结果只在阶段内存缓存，已 dispatched 的重放走 readStageResult → LOST。
    if (typeof body.requestID === "string" && body.requestID.length > 0) {
      controlStore.replayOrThrow({ requestId: body.requestID, subject, kind: `stage:${stage}`, requestHash });
    }

    // verify 候选包先与 candidates 阶段的内存响应比对（T34），比对失败不占用阶段 claim
    if (verifyInput) {
      const current = runStore.get(runId);
      const candidatesStage = runStore.readStageResult({
        run: current,
        stage: "candidates",
        requestHash: current?.candidate_request_hash,
      });
      if (!candidatesStage.hit) {
        // 重启/淘汰后绝不重调模型补结果（T17）
        throw new GatewayError("DISCOVERY_STAGE_RESULT_LOST", "Candidates result is no longer available", 410);
      }
      const candidatesHash = canonicalSha256(candidatesStage.envelope.candidates);
      if (candidatesHash !== verifyInput.submittedHash) {
        throw new GatewayError("DISCOVERY_CANDIDATE_MISMATCH", "Submitted candidates differ from the generated set", 409);
      }
    }

    // 同阶段不可变 request hash：换 body 即冲突（03 §3.4 两次调用间不能换文案）
    runStore.claimStageRequest({ run, stage, requestHash });

    // 阶段幂等键落台账（同 requestId 不同 body → 409；同键同 body 不从这里恢复结果，
    // 结果只在阶段内存缓存，已 dispatched 的重放走 readStageResult → LOST）
    if (typeof body.requestID === "string" && body.requestID.length > 0) {
      controlStore.recordRequest({
        requestId: body.requestID, subject, kind: `stage:${stage}`, requestHash, status: "committed",
      });
    }

    const cached = runStore.readStageResult({ run: runStore.get(runId), stage, requestHash });
    if (cached.hit) {
      return stageResponse({
        run: runStore.get(runId), stage, purpose, envelope: cached.envelope, usage: null, replayed: true,
        promptVersion: getPrompt(promptTypeForPurpose(purpose))?.version ?? 1,
      });
    }

    return await callModel({
      subject, deviceId, run: runStore.get(runId), stage, purpose, body, verifyInput,
      sessionId: getSessionId(context),
      language: context.req.header("x-holo-language"),
    });
  }

  async function callModel({ subject, deviceId, run, stage, purpose, body, verifyInput, sessionId, language }) {
    const route = config.routes[purpose];
    if (!route) {
      throw new GatewayError("MODEL_UNAVAILABLE", `Provider unavailable for ${purpose}`, 503);
    }
    const provider = providers.get(route.provider);
    if (!provider) {
      throw new GatewayError("MODEL_UNAVAILABLE", `Provider unavailable: ${route.provider}`, 503);
    }

    // dispatch 前先落库：进程崩溃也不得把「已发生」当「未发生」退款重试（03 §4.2）
    runStore.markDispatched({ run, stage });

    const serverPrompt = injectServerPrompt(purpose, [{
      role: "user",
      content: buildUserContent(run, stage, body, verifyInput),
    }], {
      language,
      // 个人档案通道：profileBrief 与 data 平级（不进 dataHash——发现幂等键锚定环境数据，
      // 档案更新不应触发阶段 409）
      profileBrief: typeof body.profileBrief === "string" ? body.profileBrief : undefined,
      profileChannelEnabled: config.profileChannel?.enabled,
      profileBriefMaxBytes: config.limits?.profileBriefMaxBytes,
    });

    let logId = null;
    const finishLog = (payload) => {
      if (logId) adminLogStore.finishAiCall(logId, payload);
    };
    if (captureAiCallLogs) {
      // metadata-only purpose：request/response 只传白名单键，正文任何情况下不进日志
      logId = adminLogStore.startAiCall({
        deviceId,
        purpose,
        sessionId,
        provider: route.provider,
        model: route.model,
        promptType: serverPrompt.promptType,
        promptVersion: serverPrompt.promptVersion,
        stream: false,
        request: {
          stage,
          runId: run.run_id,
          messageCount: serverPrompt.messages.length,
          messageRoles: serverPrompt.messages.map((message) => message.role),
          contentLength: Buffer.byteLength(String(serverPrompt.messages.at(-1).content ?? ""), "utf8"),
          responseFormat: null,
        },
      });
    }

    const upstreamRequest = {
      purpose,
      messages: serverPrompt.messages,
      stream: false,
      model: route.model,
      temperature: route.temperature,
      maxTokens: route.maxTokens,
      reasoningEffort: route.reasoningEffort,
      responseFormat: config.discovery.responseFormat ?? { type: "json_object" },
    };

    try {
      // 主体域显式建立：即使入口中间件未命中路径（前缀匹配回退），
      // 已 wrap 的 provider 也能以正确 subject 预留——不额外 reserveDirect，不会双份计费。
      const invoke = typeof provider.completeViaStream === "function"
        ? provider.completeViaStream.bind(provider)
        : provider.complete.bind(provider);
      // 2026-11-01 格式失误自动重试：qwen 真实材料的候选输出合格率不稳（实测 1/4；
      // 合成试评 18/18 全绿掩盖了这一差距），而单次 OUTPUT_INVALID 即关 run 烧掉当日
      // 名额 → 当天功能报废（客户端还排次日重试，用户连续多日看不到发现）。
      // OUTPUT_INVALID 属「模型已计费但产物不合格」：同 run 内最多重试 2 次（总尝试 3 次），
      // 独立成功率 p 时批次成功率 1-(1-p)^3（p=25% → ~58%，p=50% → ~87%）。
      // 每次失败把 reason+原始输出尾部打进容器日志，供 prompt 继续调优。
      // 仅重试格式类失败；预算/上游断连等其余失败立即走原路径（不放大成本）。
      const attemptOnce = async (attempt, lastRejectReason) => {
        // 2026-11-01 纠错重试：qwen 对静态规则的遵从每轮随机失手（实测 scopeKind/
        // claims_count/metricIDs 各轮不同），同 prompt 盲重试同错率高。attempt≥2 时把
        // 上轮拒因注入消息尾部带反馈重写（与 agent 纠错轮同型的成熟模式）。
        const messages = attempt === 1 || !lastRejectReason
          ? upstreamRequest.messages
          : [
              ...upstreamRequest.messages,
              { role: "user", content: `你上一次的输出未通过格式校验，被拒原因：${lastRejectReason}。请严格按系统提示词的全部规则重新输出完整的 JSON（不是修补片段），特别核对被拒原因对应的字段。` },
            ];
        const result = backgroundCostGuard
          ? await backgroundCostGuard.run(subject, () => invoke({ ...upstreamRequest, messages }))
          : await invoke({ ...upstreamRequest, messages });
        const content = result?.choices?.[0]?.message?.content ?? "";
        const { envelope } = validateDiscoveryOutput(content, {
          expectedKind: stage === "candidates" ? "candidates" : "verification",
          expectedRunID: run.run_id,
        });
        return { envelope, usage: result?.usage ?? null };
      };
      let validated;
      let lastRejectReason = null;
      for (let attempt = 1; ; attempt++) {
        try {
          validated = await attemptOnce(attempt, lastRejectReason);
          break;
        } catch (error) {
          const isFormatError = error instanceof GatewayError
            && error.code === "DISCOVERY_MODEL_OUTPUT_INVALID";
          if (!isFormatError || attempt >= 3) throw error;
          const details = error.details ?? {};
          lastRejectReason = details.reason ?? "unknown";
          console.warn(`[discovery] ${stage} output invalid attempt=${attempt}/3 run=${run.run_id}`
            + ` reason=${JSON.stringify(details.reason ?? null)} rawTail=${JSON.stringify(details.rawTail ?? "")}`);
        }
      }
      const { envelope, usage: stageUsage } = validated;

      if (stage === "candidates" && envelope.candidates.length > 0) {
        // 2026-11-01 引用锚定修复：qwen 引用时常轻微改写原文（换词/补字/标点差异）导致客户端
        // 逐字闸全拒（实测 quote_mismatch 拒因）。修复策略：引用的前后缀若能在对应证据原文中
        // 锚定（各自唯一命中同一段），则把引用整体替换为原文的精确片段——引用内容回归原文本身，
        // 语义零生成。锚不定的引用保持原样（交给客户端闸如实拒绝）。
        const evidenceBlocks = new Map();
        for (const item of Array.isArray(body.data?.evidence) ? body.data.evidence : []) {
          if (item && typeof item.evidenceID === "string" && typeof item.sourceBlock === "string") {
            evidenceBlocks.set(item.evidenceID, item.sourceBlock);
          }
        }
        let repairedCount = 0;
        const normKey = (s) => String(s).replace(/[\s“”「」『』]/g, "").toLowerCase();
        for (const candidate of envelope.candidates) {
          for (const claim of candidate.claims ?? []) {
            for (const citation of claim.citations ?? []) {
              const source = evidenceBlocks.get(citation.evidenceID);
              if (typeof source !== "string" || source.includes(citation.quote)) continue;
              const key = normKey(citation.quote);
              if (key.length < 8) continue;
              const sourceKey = normKey(source);
              const prefix = key.slice(0, 8);
              const suffix = key.slice(-8);
              const start = sourceKey.indexOf(prefix);
              if (start < 0) continue;
              const end = sourceKey.lastIndexOf(suffix);
              if (end < start) continue;
              // 命中区间按归一化长度截取原文（归一化只删空白/引号，长度差有限，按区间就近回取）
              let rawStart = start, rawEnd = end + 8;
              if (rawEnd > source.length) rawEnd = source.length;
              const anchored = source.slice(rawStart, rawEnd);
              if (anchored.length >= 6) {
                citation.quote = anchored;
                repairedCount++;
              }
            }
          }
        }
        if (repairedCount > 0) {
          console.warn(`[discovery] quote anchored repaired=${repairedCount} run=${run.run_id}`);
        }
      }
      runStore.cacheStageResult({ runId: run.run_id, stage, requestHash: stageRequestHash(stage, run.run_id, { dataHash: canonicalSha256(body.data) }), envelope });
      if (stage === "candidates" && envelope.candidates.length === 0) {
        // 无结构合格候选不调用 verify（03 §4.2）；noFinding 是成功终态，日批次按已用计
        runStore.completeRun({ runId: run.run_id, status: "completed" });
      }
      if (stage === "verify") {
        runStore.completeRun({ runId: run.run_id, status: "completed" });
      }

      finishLog({
        status: "success",
        response: {
          stage,
          status: "success",
          outcome: stage === "candidates" ? (envelope.candidates.length > 0 ? "candidates" : "no_finding") : "verification",
          runId: run.run_id,
          resultCount: stage === "candidates" ? envelope.candidates.length : envelope.candidateResults.length,
        },
        usage: stageUsage,
      });
      return stageResponse({
        run, stage, purpose, envelope, usage: stageUsage, replayed: false,
        promptVersion: serverPrompt.promptVersion,
      });
    } catch (error) {
      finishLog({
        status: "error",
        error: error instanceof GatewayError
          ? { code: error.code, status: error.status }
          : { code: "UPSTREAM_ERROR" },
        usage: null,
      });
      // 上游调用确认未发生（预算/输入校验在 reserve 拒绝、prompt 缺失）：释放当日名额（03 §4.2）
      const preUpstream = error instanceof GatewayError
        && PRE_UPSTREAM_ERROR_CODES.has(error.code);
      if (preUpstream && stage === "candidates") {
        runStore.releaseUndispatched(run.run_id);
      } else {
        // dispatch 后失败：本阶段不重复调用，保守终止本批（03 §4.4）
        runStore.completeRun({ runId: run.run_id, status: "cancelled" });
      }
      throw error;
    }
  }

  function buildUserContent(run, stage, body, verifyInput) {
    if (stage === "candidates") {
      return JSON.stringify(body.data);
    }
    return JSON.stringify({ ...body.data, runID: run.run_id, candidates: verifyInput.candidates });
  }

  // 上游 usage 是 OpenAI 形状（prompt_tokens 等 snake_case），iOS StageUsage 按
  // camelCase 解码——原样透传则客户端三个字段永远为 nil（Optional 容忍不崩，
  // 但 token 统计恒空，2026-10-30 审计 D7）。两种键名都归一成 camelCase
  function normalizeUsage(usage) {
    if (!usage || typeof usage !== "object") return usage ?? null;
    const pick = (camel, snake) => {
      const value = usage[camel] ?? usage[snake];
      return typeof value === "number" ? value : null;
    };
    return {
      promptTokens: pick("promptTokens", "prompt_tokens"),
      completionTokens: pick("completionTokens", "completion_tokens"),
      totalTokens: pick("totalTokens", "total_tokens"),
    };
  }

  function stageResponse({ run, stage, purpose, envelope, usage, replayed, promptVersion }) {
    const route = config.routes[purpose];
    const base = {
      runID: run.run_id,
      stage,
      envelope,
      promptType: promptTypeForPurpose(purpose),
      promptVersion: promptVersion ?? getPrompt(promptTypeForPurpose(purpose))?.version ?? 1,
      model: { provider: route?.provider ?? null, model: route?.model ?? null },
      usage: normalizeUsage(usage),
      replayed,
    };
    if (stage === "candidates") {
      return { ...base, candidatesHash: canonicalSha256(envelope.candidates) };
    }
    return base;
  }
}

function stageRequestHash(kind, runId, payload) {
  // 简单拼接已足够：runId 唯一 + kind 分离 + dataHash 碰撞概率由 sha256 承担
  return `${kind}:${runId}:${payload.sourceManifestDigest ?? payload.dataHash ?? ""}`;
}

// 这些错误发生在真实上游调用之前（reserve/参数检查阶段）：可确认模型未触达，
// 按未 dispatch 处理释放当日名额；其余失败保守按已 dispatch 终止本批。
const PRE_UPSTREAM_ERROR_CODES = new Set([
  "BACKGROUND_BUDGET_EXCEEDED",
  "BACKGROUND_INPUT_TOO_LARGE",
  "PROMPT_NOT_FOUND",
  "MODEL_UNAVAILABLE",
]);

function requireFields(body, fields) {
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    throw new GatewayError("INVALID_REQUEST", "Request body must be an object", 400);
  }
  for (const field of fields) {
    if (!Object.hasOwn(body, field)) {
      throw new GatewayError("INVALID_REQUEST", `${field} is required`, 400);
    }
  }
}

function requireInt(value, field) {
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 0) {
    throw new GatewayError("INVALID_REQUEST", `${field} must be a non-negative integer`, 400);
  }
  return parsed;
}

function requireId(value, field) {
  if (typeof value !== "string" || value.length < 1 || value.length > 128) {
    throw new GatewayError("INVALID_REQUEST", `${field} must be 1-128 chars`, 400);
  }
  return value;
}

function optionalString(value, max) {
  if (value === undefined || value === null) return null;
  if (typeof value !== "string" || value.length > max) {
    throw new GatewayError("INVALID_REQUEST", `string field exceeds ${max} chars`, 400);
  }
  return value;
}
