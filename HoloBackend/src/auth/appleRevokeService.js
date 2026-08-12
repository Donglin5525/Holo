import { SignJWT, importPKCS8 } from "jose";

const APPLE_REVOKE_URL = "https://appleid.apple.com/auth/revoke";
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

  async function revoke(identityToken) {
    if (typeof identityToken !== "string" || identityToken.length === 0) {
      throw new Error("Apple identity token is required");
    }
    if (!isConfigured()) {
      throw new Error("APPLE_REVOKE_NOT_CONFIGURED");
    }
    const clientSecret = await buildClientSecret();
    const body = new URLSearchParams({
      client_id: clientId,
      client_secret: clientSecret,
      token: identityToken,
      token_type_hint: "id_token",
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

  return { revoke, buildClientSecret, isConfigured };
}

// .p8 的 PEM 存环境变量时换行常被转成字面 \n，这里还原成真实换行
function normalizePem(value) {
  return value.replace(/\\n/g, "\n").trim();
}
