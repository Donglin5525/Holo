export class GatewayError extends Error {
  constructor(code, message, status = 500) {
    super(message);
    this.name = "GatewayError";
    this.code = code;
    this.status = status;
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

    // 兜底
    INTERNAL_ERROR: "服务暂时不可用，请稍后重试",
  };

  return messages[code] ?? "服务暂时不可用，请稍后重试";
}
