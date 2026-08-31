/**
 * APNs Provider API 发送器（云端分析完成通知）
 * - 鉴权：ES256 JWT（.p8 私钥，jose 签名；iss=TeamID kid=KeyID），缓存 40 分钟刷新
 * - 传输：HTTP/2 直连 api.push.apple.com / api.sandbox.push.apple.com（连接复用）
 * - 环境策略：iOS 端无法可靠自知 sandbox/production，token 行无已验证环境时
 *   先发 production，400 BadDeviceToken 回退 sandbox；成功后回写 environment 直发
 * - 410 Unregistered = 设备已卸载，调用方删 token 行
 * - 未配置密钥时返回 disabled（调用方跳过发送，功能整体 no-op）
 */

import http2 from "node:http2";
import { SignJWT, importPKCS8 } from "jose";

const JWT_TTL_MS = 40 * 60 * 1000;

export function createApnsSender({
  keyPem,
  keyId,
  teamId,
  bundleId,
  connect = http2.connect,
  now = () => Date.now(),
  log = () => {},
} = {}) {
  if (!keyPem || !keyId || !teamId || !bundleId) {
    return { configured: false, send: async () => ({ ok: false, skipped: "not_configured" }) };
  }

  let cachedJwt = null;
  let cachedJwtAt = 0;
  const sessions = new Map();

  async function currentJwt() {
    if (cachedJwt && now() - cachedJwtAt < JWT_TTL_MS) return cachedJwt;
    const privateKey = await importPKCS8(keyPem, "ES256");
    cachedJwt = await new SignJWT({})
      .setProtectedHeader({ alg: "ES256", kid: keyId })
      .setIssuedAt()
      .setIssuer(teamId)
      .setExpirationTime("1h")
      .sign(privateKey);
    cachedJwtAt = now();
    return cachedJwt;
  }

  function session(authority) {
    let client = sessions.get(authority);
    if (!client || client.destroyed || client.closed) {
      client = connect(authority);
      client.on("error", (error) => {
        log(`APNs 连接错误 ${authority}: ${error?.message ?? error}`);
        sessions.delete(authority);
      });
      sessions.set(authority, client);
    }
    return client;
  }

  /**
   * 单环境发送。返回 {ok} 或 {ok:false, status, reason, body}。
   * reason: badDeviceToken（环境不符/非法）/ unregistered（410，应删 token）/ error
   */
  function sendOnce({ token, environment, title, body, collapseId, threadId }) {
    const authority = environment === "sandbox"
      ? "https://api.sandbox.push.apple.com"
      : "https://api.push.apple.com";
    return new Promise((resolve) => {
      let settled = false;
      const finish = (value) => {
        if (!settled) { settled = true; resolve(value); }
      };
      let request;
      try {
        request = session(authority).request({
          ":method": "POST",
          ":path": `/3/device/${encodeURIComponent(token)}`,
          "authorization": `bearer ${cachedJwt}`,
          "apns-topic": bundleId,
          "apns-push-type": "alert",
          ...(collapseId ? { "apns-collapse-id": collapseId } : {}),
          ...(threadId ? { "apns-thread-id": threadId } : {}),
          "content-type": "application/json",
        });
      } catch (error) {
        finish({ ok: false, reason: "error", message: String(error?.message ?? error) });
        return;
      }
      request.setTimeout(10_000, () => {
        request.close(http2.constants.NGHTTP2_CANCEL);
        finish({ ok: false, reason: "timeout" });
      });
      request.on("response", (headers) => {
        const status = headers[":status"];
        let raw = "";
        request.setEncoding("utf8");
        request.on("data", (chunk) => { raw += chunk; });
        request.on("end", () => {
          if (status === 200) return finish({ ok: true });
          let bodyText = raw;
          try { bodyText = JSON.parse(raw)?.reason ?? raw; } catch { /* keep raw */ }
          if (status === 410) {
            finish({ ok: false, status, reason: "unregistered", apnsReason: bodyText });
          } else if (status === 400 && String(bodyText).includes("BadDeviceToken")) {
            finish({ ok: false, status, reason: "badDeviceToken", apnsReason: bodyText });
          } else {
            finish({ ok: false, status, reason: "error", apnsReason: bodyText });
          }
        });
      });
      request.on("error", (error) => finish({ ok: false, reason: "error", message: String(error?.message ?? error) }));
      request.end(JSON.stringify({
        aps: {
          alert: { title, body },
          sound: "default",
          "thread-id": threadId ?? "cloud-analysis",
        },
      }));
    });
  }

  /**
   * 发送通知（带环境回退）。
   * @returns {Promise<{ok:boolean, environment?:string, reason?:string, apnsReason?:string}>}
   * environment = 实际成功（或尝试）的环境，调用方可回写缓存。
   */
  async function send({ token, environment, title, body, collapseId, threadId }) {
    await currentJwt();
    const preferred = environment === "sandbox" || environment === "production" ? environment : "production";
    let result = await sendOnce({ token, environment: preferred, title, body, collapseId, threadId });
    if (!result.ok && result.reason === "badDeviceToken" && preferred === "production") {
      const fallbackEnv = "sandbox";
      const fallback = await sendOnce({ token, environment: fallbackEnv, title, body, collapseId, threadId });
      if (fallback.ok) {
        return { ...fallback, environment: fallbackEnv };
      }
      result = fallback.reason ? fallback : result;
      return { ok: false, environment: fallbackEnv, reason: result.reason ?? "badDeviceToken", apnsReason: result.apnsReason };
    }
    return { ...result, environment: preferred };
  }

  return { configured: true, send };
}
