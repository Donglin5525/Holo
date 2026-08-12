import Green20220302, { TextModerationPlusRequest } from "@alicloud/green20220302";

// @alicloud/green20220302 是 CommonJS 模块，ESM 默认导入拿到的是 module.exports，
// 真正的 Client 构造器挂在其 .default 上。
const GreenClient = Green20220302.default;

/**
 * AI 内容安全审核（App Store Guideline 1.2）。
 *
 * 封装阿里云文本审核增强版（textModerationPlus）。设计原则：
 * - 无凭证时 isEnabled() 为 false，moderate() 直接降级放行，不阻断 AI；
 *   东林在环境变量配置 AccessKey 后自动生效。
 * - 审核服务本身异常（HTTP 非 200 / SDK 抛错）时降级放行，避免审核故障导致所有 AI 不可用。
 * - 仅命中违规才拦截。
 *
 * @param {object} options
 * @param {string} [options.accessKeyId]     阿里云 AccessKey Id
 * @param {string} [options.accessKeySecret] 阿里云 AccessKey Secret
 * @param {string} [options.endpoint]        审核服务接入点
 * @param {string} [options.service]         审核服务标识（默认 chat_detection_pro）
 * @param {boolean} [options.enabled]        总开关，默认 true；设 false 强制关闭
 * @param {Function} [options.moderateImpl]  测试注入：替换 SDK 调用，返回 { body } 形态响应
 */
export function createContentModerationService(options = {}) {
  const accessKeyId = options.accessKeyId ?? "";
  const accessKeySecret = options.accessKeySecret ?? "";
  const endpoint = options.endpoint ?? "green-cip.cn-shanghai.aliyuncs.com";
  const service = options.service ?? "chat_detection_pro";
  const enabled = options.enabled !== false;
  const moderateImpl = options.moderateImpl ?? null;

  // lazy 初始化：无凭证时不 new client，避免构造时校验报错。
  let client = null;
  function getClient() {
    if (!client) {
      client = new GreenClient({ accessKeyId, accessKeySecret, endpoint });
    }
    return client;
  }

  function isEnabled() {
    return enabled && Boolean(accessKeyId && accessKeySecret);
  }

  /**
   * @param {string} text 待审文本
   * @returns {Promise<{passed: boolean, reason?: string, labels?: string[], riskLevel?: string|null}>}
   */
  async function moderate(text) {
    if (!isEnabled()) {
      return { passed: true, reason: "disabled" };
    }
    if (typeof text !== "string" || text.length === 0) {
      return { passed: true };
    }

    let response;
    try {
      // moderateImpl 替换 SDK 调用（测试用）；否则真实调用阿里云文本审核增强版。
      response = moderateImpl
        ? await moderateImpl(text)
        : await getClient().textModerationPlus(
            new TextModerationPlusRequest({
              service,
              serviceParameters: JSON.stringify({ content: text }),
            }),
          );
    } catch {
      // 网络故障 / 鉴权失败等：降级放行，不阻断 AI。
      return { passed: true, reason: "service-error" };
    }

    const body = response?.body ?? {};
    if (body.code !== 200) {
      // 审核服务返回非成功状态：降级放行。
      return { passed: true, reason: "service-error" };
    }

    const results = body.data?.result ?? [];
    const hits = results.filter((item) => item.label && item.label !== "nonLabel");
    if (hits.length > 0) {
      return {
        passed: false,
        labels: hits.map((item) => item.label),
        riskLevel: body.data?.riskLevel ?? null,
      };
    }
    return { passed: true };
  }

  return { isEnabled, moderate };
}
