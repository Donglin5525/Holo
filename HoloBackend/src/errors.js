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

function publicMessage(code) {
  const messages = {
    APP_ATTEST_REQUIRED: "安全校验失败，请更新 App 或稍后重试",
    AUDIO_TOO_LARGE: "语音文件过大，请缩短录音后重试",
    INVALID_CLIENT_ROUTING: "请求参数无效",
    INVALID_JSON: "请求格式无效",
    INVALID_REQUEST: "请求参数无效",
    MODEL_UNAVAILABLE: "模型服务暂时不可用，请稍后重试",
    RATE_LIMITED: "今天的 AI 使用次数已达上限，稍后再试",
    UNKNOWN_PURPOSE: "请求的 AI 功能暂不可用",
    UPSTREAM_AUTH_FAILED: "模型服务鉴权失败，请稍后重试",
    UPSTREAM_TIMEOUT: "模型响应超时，请稍后重试",
  };

  return messages[code] ?? "服务暂时不可用，请稍后重试";
}
