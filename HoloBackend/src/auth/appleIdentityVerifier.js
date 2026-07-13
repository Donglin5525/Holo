import { createLocalJWKSet, createRemoteJWKSet, jwtVerify } from "jose";

const APPLE_ISSUER = "https://appleid.apple.com";
const APPLE_JWKS_URL = "https://appleid.apple.com/auth/keys";

export function createAppleIdentityVerifier(options = {}) {
  const clientIds = uniqueStrings(options.clientIds ?? []);
  if (clientIds.length === 0) {
    throw new Error("Apple client IDs are required");
  }

  const keySet = options.jwks
    ? createLocalJWKSet(options.jwks)
    : createRemoteJWKSet(new URL(options.jwksURL ?? APPLE_JWKS_URL));
  const issuer = options.issuer ?? APPLE_ISSUER;
  const now = options.now ?? (() => new Date());

  return {
    async verify(identityToken) {
      if (typeof identityToken !== "string" || identityToken.length === 0) {
        throw new Error("Apple identity token is required");
      }

      const { payload } = await jwtVerify(identityToken, keySet, {
        algorithms: ["RS256"],
        issuer,
        audience: clientIds,
        currentDate: now(),
      });

      if (typeof payload.sub !== "string" || payload.sub.length === 0) {
        throw new Error("Apple identity subject is missing");
      }

      const audience = Array.isArray(payload.aud) ? payload.aud[0] : payload.aud;
      return {
        sub: payload.sub,
        audience,
      };
    },
  };
}

function uniqueStrings(values) {
  return [...new Set(values.map((value) => String(value).trim()).filter(Boolean))];
}
