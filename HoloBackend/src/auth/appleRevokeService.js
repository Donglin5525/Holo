import { SignJWT, importPKCS8 } from "jose";

const APPLE_REVOKE_URL = "https://appleid.apple.com/auth/revoke";
const APPLE_TOKEN_URL = "https://appleid.apple.com/auth/oauth2/token";
const APPLE_AUDIENCE = "https://appleid.apple.com";
// client_secret 有效期上限 6 个月
const CLIENT_SECRET_TTL_SECONDS = 15777000;

export function createAppleRevokeService(options = {}) {
  const teamId = options.teamId ?? "";
  const keyId = options.keyId ?? "";
  const clientId = options.clientId ?? "";
  const privateKeyPem = normalizePem(options.privateKeyPem ?? "");
  const fetchImpl = options.fetch ?? fetch;

  function isConfigured() {
    return Boolean(teamId && keyId && clientId && privateKeyPem);
  }

  async function buildClientSecret(now = new Date()) {
    if (!isConfigured()) {
      throw new Error("Apple revoke credentials are not configured");
    }
    const key = await importPKCS8(privateKeyPem, "ES256");
    const issuedAt = Math.floor(now.getTime() / 1000);
    return new SignJWT({})
      .setProtectedHeader({ alg: "ES256", kid: keyId })
      .setIssuer(teamId)
      .setIssuedAt(issuedAt)
      .setExpirationTime(issuedAt + CLIENT_SECRET_TTL_SECONDS)
      .setAudience(APPLE_AUDIENCE)
      .setSubject(clientId)
      .sign(key);
  }

  // P02（2026-10-04 体检）：撤销接口只认 access/refresh token——此前误传
  // identity token + id_token hint，撤销从未真正生效。现在撤销一律用
  // 登录时授权码换来的 refresh token（见 exchangeAuthorizationCode）。
  async function revoke(refreshToken) {
    if (typeof refreshToken !== "string" || refreshToken.length === 0) {
      throw new Error("Apple refresh token is required");
    }
    if (!isConfigured()) {
      throw new Error("APPLE_REVOKE_NOT_CONFIGURED");
    }
    const clientSecret = await buildClientSecret();
    const body = new URLSearchParams({
      client_id: clientId,
      client_secret: clientSecret,
      token: refreshToken,
      token_type_hint: "refresh_token",
    });
    const response = await fetchImpl(APPLE_REVOKE_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: body.toString(),
    });
    if (!response.ok) {
      throw new Error(`Apple revoke failed with status ${response.status}`);
    }
    return { ok: true };
  }

  // 登录时用授权码换 token 对（TN3194：账号删除撤销链路的凭证来源）。
  // refresh_token 长期有效且可撤销，由 appleTokenStore 加密留存。
  async function exchangeAuthorizationCode(authorizationCode) {
    if (typeof authorizationCode !== "string" || authorizationCode.length === 0) {
      throw new Error("Apple authorization code is required");
    }
    if (!isConfigured()) {
      throw new Error("APPLE_REVOKE_NOT_CONFIGURED");
    }
    const clientSecret = await buildClientSecret();
    const body = new URLSearchParams({
      grant_type: "authorization_code",
      code: authorizationCode,
      client_id: clientId,
      client_secret: clientSecret,
    });
    const response = await fetchImpl(APPLE_TOKEN_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: body.toString(),
    });
    if (!response.ok) {
      throw new Error(`Apple token exchange failed with status ${response.status}`);
    }
    const payload = await response.json();
    if (typeof payload.refresh_token !== "string" || payload.refresh_token.length === 0) {
      throw new Error("Apple token exchange returned no refresh token");
    }
    return { refreshToken: payload.refresh_token };
  }

  return { revoke, exchangeAuthorizationCode, buildClientSecret, isConfigured };
}

// .p8 的 PEM 存环境变量时换行常被转成字面 \n，这里还原成真实换行
function normalizePem(value) {
  return value.replace(/\\n/g, "\n").trim();
}
