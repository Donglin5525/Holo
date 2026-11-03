export class GatewayError extends Error {
  constructor(code, message, status = 500, details = null) {
    super(message);
    this.name = "GatewayError";
    this.code = code;
    this.status = status;
    this.details = details;
  }
}

export function createErrorResponse(context, error) {
  const gatewayError = normalizeError(error);
  if (!(error instanceof GatewayError)) {
    console.error("[holo-backend] unexpected error", error?.name ?? "Error", error?.message ?? String(error));
  }

  return context.json(
    {
      error: {
        code: gatewayError.code,
        message: publicMessage(gatewayError.code),
        ...(gatewayError.details ?? {}),
      },
    },
    gatewayError.status,
  );
}

function normalizeError(error) {
  if (error instanceof GatewayError) {
    return error;
  }

  return new GatewayError("INTERNAL_ERROR", "Internal server error", 500);
}

export function publicMessage(code) {
  const messages = {
    // 鉴权 & 安全
    APP_ATTEST_REQUIRED: "安全校验失败，请更新 App 或稍后重试",
    AUTH_UNAVAILABLE: "内部诊断服务暂不可用",
    INVALID_APPLE_IDENTITY: "Apple 身份验证失败，请重新登录",
    INTERNAL_DIAGNOSTICS_FORBIDDEN: "你没有访问内部诊断的权限",
    INTERNAL_LOG_NOT_FOUND: "该诊断记录已过期或不存在",
    UPSTREAM_AUTH_FAILED: "模型服务暂时不可用，请稍后重试",

    // 请求参数
    INVALID_CLIENT_ROUTING: "请求参数无效",
    INVALID_JSON: "请求格式无效",
    INVALID_REQUEST: "请求参数无效",
    INVALID_CHAT_REQUEST: "请求参数无效",
    PROMPT_NOT_FOUND: "请求的功能暂不可用",
    UNKNOWN_PURPOSE: "请求的 AI 功能暂不可用",

    // 频率限制
    RATE_LIMITED: "今天的 AI 使用次数已达上限，稍后再试",
    REPORT_RATE_LIMITED: "举报提交过于频繁，请稍后再试",
    QUOTA_EXCEEDED: "当前会员额度已用完",
    BACKGROUND_BUDGET_EXCEEDED: "后台整理额度已用完，将在额度恢复后继续，不影响已有记录和主动聊天",
    BACKGROUND_CLIENT_UPDATE_REQUIRED: "请更新 App 以继续后台整理，已有记录不受影响",
    BACKGROUND_INPUT_TOO_LARGE: "本次后台整理内容过多，请更新 App 后重试",
    BACKGROUND_RETRY_DEFERRED: "这批内容暂时无法整理，已暂停重复尝试",
    BACKGROUND_CONTEXT_REQUIRED: "后台整理暂不可用，请稍后重试",
    ASR_DURATION_EXCEEDED: "本次录音超过当前会员可识别时长",

    // 订阅与验收
    SUBSCRIPTION_VERIFICATION_UNAVAILABLE: "订阅验证服务暂不可用",
    INVALID_PRODUCT_ID: "订阅商品无效",
    INVALID_TRANSACTION: "订阅交易验证失败",
    INVALID_ACCEPTANCE_MODE: "真机验收模式无效",
    ACCEPTANCE_MODE_REQUIRED: "请先切换到免费或 Plus 真机验收模式",

    // Agent step 幂等
    STEP_ID_CONFLICT: "任务步骤与请求内容不匹配，请重新开始分析",
    STEP_IN_PROGRESS: "该分析步骤正在执行中，请稍后重试",

    // 语音相关
    AUDIO_TOO_LARGE: "语音文件过大，请缩短录音后重试",
    EMPTY_TRANSCRIPT: "未能识别语音内容，请再试一次",

    // 上游服务
    MODEL_UNAVAILABLE: "模型服务暂时不可用，请稍后重试",
    UPSTREAM_TIMEOUT: "模型响应超时，请稍后重试",
    UPSTREAM_ERROR: "模型服务暂时不可用，请稍后重试",
    EMPTY_MODEL_RESPONSE: "模型未返回有效内容，请稍后重试",
    TRUNCATED_MODEL_RESPONSE: "模型返回内容不完整，请稍后重试",
    INVALID_INSIGHT_JSON: "模型返回格式异常，请稍后重试",

    // 想法自动整理 V2
    THOUGHT_ORGANIZE_DISABLED: "自动整理暂未开放",
    PRIVACY_ROUTE_UNVERIFIED: "该功能正在配置中，暂时不可用",
    INPUT_TOO_LARGE: "这条内容过长，暂时无法自动整理",
    OPERATION_IN_PROGRESS: "这条想法正在整理中，请稍候",
    BUDGET_EXCEEDED: "今天的自动整理额度已用完，明天会自动恢复",
    MODEL_OUTPUT_INVALID: "整理结果异常，稍后会自动重试",

    // 兜底
    INTERNAL_ERROR: "服务暂时不可用，请稍后重试",

    // HoloAI「一个发现」（2026-10-23 实施包 G3）
    DISCOVERY_DISABLED: "这个功能还没有开放",
    DISCOVERY_REVISION_CONFLICT: "设置已在其他设备上更新，请刷新后再试",
    DISCOVERY_TAKEOVER_REQUIRED: "另一台设备正在负责自动准备，确认接管后才能切换",
    DISCOVERY_REQUEST_CONFLICT: "请求与已提交的操作不一致，请刷新后重试",
    DISCOVERY_DAY_LIMIT: "今天已经准备过一次发现，明天会自动继续",
    DISCOVERY_RUN_NOT_FOUND: "这次准备任务不存在或已结束",
    DISCOVERY_RUN_NOT_OWNER: "当前设备不负责自动准备",
    DISCOVERY_RUN_CLOSED: "这次准备任务已结束",
    DISCOVERY_RUN_CONFLICT: "准备任务编号已被使用，请重新开始",
    DISCOVERY_LEASE_EXPIRED: "这次准备超时结束，稍后会自动重试",
    DISCOVERY_RUN_TOKEN_INVALID: "准备任务凭证无效，请重新开始",
    DISCOVERY_STAGE_ORDER: "准备步骤还未到核验阶段",
    DISCOVERY_STAGE_CONFLICT: "该步骤已用不同内容提交过，请重新开始",
    DISCOVERY_STAGE_RESULT_LOST: "这次准备的结果已过期，本批自动终止，不影响已有发现",
    DISCOVERY_CONTROL_CHANGED: "发现设置已变化，这次准备自动终止",
    DISCOVERY_CONTROL_DISABLED: "发现功能已关闭",
    DISCOVERY_MODEL_OUTPUT_INVALID: "本次结果未通过核验门槛，已自动放弃，不影响已有记录",
    DISCOVERY_CANDIDATE_MISMATCH: "候选内容与生成结果不一致，请重新开始",
    DISCOVERY_HASH_MISMATCH: "数据校验不一致，请重新开始",
    DISCOVERY_INPUT_TOO_LARGE: "这次准备的材料过多，请缩小来源范围",
    DISCOVERY_PURPOSE_BYPASS_BLOCKED: "请求的 AI 功能暂不可用",
  };

  return messages[code] ?? "服务暂时不可用，请稍后重试";
}
