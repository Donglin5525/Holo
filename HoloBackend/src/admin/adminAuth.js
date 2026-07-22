import { createHmac, timingSafeEqual } from "node:crypto";

const SESSION_COOKIE_NAME = "holo_admin_session";
const SESSION_TTL_SECONDS = 12 * 60 * 60;

export function isAdminEnabled(config) {
  return hasAdminToken(config) || hasPasswordLogin(config);
}

export function assertAdminAuthorized(context, config) {
  if (!isAdminEnabled(config)) {
    return {
      ok: false,
      status: 404,
      body: { error: { code: "ADMIN_DISABLED", message: "Admin endpoints are disabled" } },
    };
  }

  const providedToken = context.req.header("x-holo-admin-token") ?? context.req.query("token") ?? "";
  if (hasAdminToken(config) && tokensEqual(providedToken, config.admin.token)) {
    return { ok: true };
  }

  if (isValidSessionCookie(context.req.header("cookie") ?? "", config)) {
    return { ok: true };
  }

  return {
    ok: false,
    status: 401,
    body: { error: { code: "ADMIN_UNAUTHORIZED", message: "Admin credentials are invalid" } },
  };
}

export function isPasswordLoginEnabled(config) {
  return hasPasswordLogin(config);
}

export function validateAdminLogin(config, { username, password }) {
  if (!hasPasswordLogin(config)) {
    return false;
  }

  return tokensEqual(username, config.admin.username) && tokensEqual(password, config.admin.password);
}

export function createAdminSessionCookie(config) {
  const now = Math.floor(Date.now() / 1000);
  const payload = base64UrlEncode(
    JSON.stringify({
      sub: config.admin.username,
      exp: now + SESSION_TTL_SECONDS,
    }),
  );
  const signature = sign(payload, config);

  const attributes = [
    `${SESSION_COOKIE_NAME}=${payload}.${signature}`,
    "Path=/",
    "HttpOnly",
    "SameSite=Strict",
    `Max-Age=${SESSION_TTL_SECONDS}`,
  ];
  if (config.runtimeEnvironment === "production") attributes.push("Secure");
  return attributes.join("; ");
}

export function clearAdminSessionCookie(config = {}) {
  const secure = config.runtimeEnvironment === "production" ? "; Secure" : "";
  return `${SESSION_COOKIE_NAME}=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0${secure}`;
}

function isValidSessionCookie(cookieHeader, config) {
  const cookie = parseCookies(cookieHeader)[SESSION_COOKIE_NAME];
  if (!cookie || !cookie.includes(".")) {
    return false;
  }

  const [payload, signature] = cookie.split(".", 2);
  if (!tokensEqual(signature, sign(payload, config))) {
    return false;
  }

  try {
    const session = JSON.parse(Buffer.from(payload, "base64url").toString("utf8"));
    return session.sub === config.admin.username && Number(session.exp) > Math.floor(Date.now() / 1000);
  } catch {
    return false;
  }
}

function parseCookies(cookieHeader) {
  return Object.fromEntries(
    cookieHeader
      .split(";")
      .map((cookie) => cookie.trim())
      .filter(Boolean)
      .map((cookie) => {
        const separator = cookie.indexOf("=");
        if (separator === -1) {
          return [cookie, ""];
        }
        return [cookie.slice(0, separator), cookie.slice(separator + 1)];
      }),
  );
}

function hasAdminToken(config) {
  return typeof config.admin.token === "string" && config.admin.token.length > 0;
}

function hasPasswordLogin(config) {
  return (
    typeof config.admin.username === "string" &&
    config.admin.username.length > 0 &&
    typeof config.admin.password === "string" &&
    config.admin.password.length > 0
  );
}

function sign(payload, config) {
  return createHmac("sha256", getSessionSecret(config)).update(payload).digest("base64url");
}

function getSessionSecret(config) {
  return config.admin.sessionSecret || config.admin.token || config.admin.password;
}

function base64UrlEncode(value) {
  return Buffer.from(value).toString("base64url");
}

function tokensEqual(left, right) {
  if (typeof left !== "string" || typeof right !== "string") {
    return false;
  }

  const leftBuffer = Buffer.from(left);
  const rightBuffer = Buffer.from(right);
  if (leftBuffer.length !== rightBuffer.length) {
    return false;
  }

  return timingSafeEqual(leftBuffer, rightBuffer);
}
