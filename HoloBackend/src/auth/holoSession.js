import { SignJWT, jwtVerify } from "jose";

const DEFAULT_ISSUER = "holo-ai-gateway";
const DEFAULT_AUDIENCE = "holo-ios";
const DEFAULT_TTL_SECONDS = 60 * 60;

export function createHoloSessionService(options = {}) {
  const secret = String(options.secret ?? "");
  if (Buffer.byteLength(secret, "utf8") < 32) {
    throw new Error("Holo session secret must be at least 32 bytes");
  }

  const signingKey = new TextEncoder().encode(secret);
  const internalSubjects = new Set(
    (options.internalSubjects ?? []).map((value) => String(value).trim()).filter(Boolean),
  );
  const issuer = options.issuer ?? DEFAULT_ISSUER;
  const audience = options.audience ?? DEFAULT_AUDIENCE;
  const ttlSeconds = Number(options.ttlSeconds ?? DEFAULT_TTL_SECONDS);
  const now = options.now ?? (() => new Date());

  return {
    async issue(subject, claims = {}) {
      if (typeof subject !== "string" || subject.length === 0) {
        throw new Error("Session subject is required");
      }
      const nowSeconds = Math.floor(now().getTime() / 1000);
      return new SignJWT({
        internalDiagnostics: internalSubjects.has(subject),
        sessionKind: claims.sessionKind ?? "apple_user",
        appAttestKeyId: claims.appAttestKeyId,
        appleSubject: claims.appleSubject,
      })
        .setProtectedHeader({ alg: "HS256", typ: "JWT" })
        .setSubject(subject)
        .setIssuer(issuer)
        .setAudience(audience)
        .setIssuedAt(nowSeconds)
        .setExpirationTime(nowSeconds + ttlSeconds)
        .sign(signingKey);
    },

    async verify(token) {
      const { payload } = await jwtVerify(token, signingKey, {
        algorithms: ["HS256"],
        issuer,
        audience,
        currentDate: now(),
      });
      if (typeof payload.sub !== "string" || payload.sub.length === 0) {
        throw new Error("Session subject is missing");
      }
      return {
        sub: payload.sub,
        internalDiagnostics: payload.internalDiagnostics === true,
        issuedAt: payload.iat,
        expiresAt: payload.exp,
        sessionKind: payload.sessionKind,
        appAttestKeyId: payload.appAttestKeyId,
        appleSubject: payload.appleSubject,
      };
    },
  };
}
