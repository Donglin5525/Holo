// 设备会话（2026-10-04 体检 S01）：把「设备编号」从自报身份升级为「持钥证明」。
//
// 背景：getDeviceId 之前无条件信任 x-holo-device-id 请求头——编号只是标识不是凭证，
// 任何人构造编号即可创建云任务（烧额度）或在他人编号边界内活动（审计复现实锤）。
//
// 机制（报告口径的「受保护匿名会话」，分阶段升级第一步）：
// 1. 客户端首装生成 Ed25519 密钥对（Keychain 持久），私钥不出设备；
// 2. POST /v1/auth/device/challenge 取一次性挑战（5 分钟有效，防重放）；
// 3. POST /v1/auth/device/session 提交 {deviceId, publicKey, signature}，signature 为
//    私钥对 "holo-device-bind:v1:<deviceId>:<challenge>" 的签名；
// 4. 服务端验签签发短效设备 JWT（aud=holo-device，sub=deviceId）；
// 5. enforceDeviceSession=true 时，getDeviceId 单点强制：请求必须携带与
//    x-holo-device-id 同主体的有效设备会话——所有设备路由自动复用同一规则。
//
// App Attest（硬件锚定）为下一阶段：把第 3 步的公钥换成经 DCAppAttestService
// 证明的公钥即可，协议结构不变。当前端点不校验硬件证明，防的是「伪造/冒用编号」，
// 不防「脚本批量自造钥匙」——后者由挑战一次性 + 限流 + 后续 App Attest 收口。
import { SignJWT, jwtVerify } from "jose";
import { createPublicKey, randomBytes, verify as cryptoVerify } from "node:crypto";

const BINDING_PAYLOAD_PREFIX = "holo-device-bind:v1:";
const DEFAULT_ISSUER = "holo-ai-gateway";
const DEVICE_AUDIENCE = "holo-device";
const DEFAULT_TTL_SECONDS = 60 * 60 * 24;
const DEFAULT_CHALLENGE_TTL_SECONDS = 300;
// 挑战池上限：内存兜底，防未限流客户端刷爆 Map；正常客户端每台同时只挂 1 个挑战
const MAX_PENDING_CHALLENGES = 10_000;

const UUID_PATTERN = /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/;

// Ed25519 原始 32 字节公钥 → SPKI DER（node:crypto 需要 SPKI/PKIX 容器）
const ED25519_SPKI_PREFIX = Buffer.from("302a300506032b6570032100", "hex");

export function ed25519PublicKeyObject(publicKeyBase64) {
  const raw = Buffer.from(String(publicKeyBase64), "base64");
  if (raw.length !== 32) {
    throw new Error("Device public key must be 32 raw bytes");
  }
  return createPublicKey({
    key: Buffer.concat([ED25519_SPKI_PREFIX, raw]),
    format: "der",
    type: "spki",
  });
}

export function bindingPayload(deviceId, challenge) {
  return `${BINDING_PAYLOAD_PREFIX}${deviceId}:${challenge}`;
}

export function createDeviceSessionService(options = {}) {
  const secret = String(options.secret ?? "");
  if (Buffer.byteLength(secret, "utf8") < 32) {
    throw new Error("Device session secret must be at least 32 bytes");
  }
  const signingKey = new TextEncoder().encode(secret);
  const issuer = options.issuer ?? DEFAULT_ISSUER;
  const ttlSeconds = Number(options.ttlSeconds ?? DEFAULT_TTL_SECONDS);
  const challengeTtlSeconds = Number(options.challengeTtlSeconds ?? DEFAULT_CHALLENGE_TTL_SECONDS);
  const now = options.now ?? (() => new Date());
  const challengeId = options.challengeId ?? (() => randomBytes(32).toString("base64url"));

  // 挑战一次性：challenge 字符串 → 签发时间。验签成功或过期即作废。
  const pendingChallenges = new Map();

  function pruneChallenges() {
    const cutoff = now().getTime() - challengeTtlSeconds * 1000;
    for (const [challenge, issuedAtMs] of pendingChallenges) {
      if (issuedAtMs <= cutoff) pendingChallenges.delete(challenge);
    }
  }

  return {
    issueChallenge() {
      pruneChallenges();
      if (pendingChallenges.size >= MAX_PENDING_CHALLENGES) {
        throw new Error("Challenge pool exhausted");
      }
      const challenge = challengeId();
      pendingChallenges.set(challenge, now().getTime());
      return { challenge, expiresInSeconds: challengeTtlSeconds };
    },

    async issueSession({ deviceId, publicKey, signature, challenge }) {
      if (typeof deviceId !== "string" || !UUID_PATTERN.test(deviceId)) {
        throw new Error("Device session requires a UUID deviceId");
      }
      if (typeof challenge !== "string" || !pendingChallenges.has(challenge)) {
        throw new Error("Device session requires a fresh challenge");
      }
      // 挑战验签后立即作废（一次性），无论后续成功与否
      pendingChallenges.delete(challenge);
      if (typeof publicKey !== "string" || publicKey.length === 0) {
        throw new Error("Device session requires a public key");
      }
      if (typeof signature !== "string" || signature.length === 0) {
        throw new Error("Device session requires a signature");
      }
      const keyObject = ed25519PublicKeyObject(publicKey);
      const payload = Buffer.from(bindingPayload(deviceId, challenge), "utf8");
      const signatureBytes = Buffer.from(signature, "base64");
      const signatureOk = cryptoVerify(null, payload, keyObject, signatureBytes);
      if (!signatureOk) {
        throw new Error("Device binding signature is invalid");
      }

      const nowSeconds = Math.floor(now().getTime() / 1000);
      return new SignJWT({ kind: "device" })
        .setProtectedHeader({ alg: "HS256", typ: "JWT" })
        .setSubject(deviceId)
        .setIssuer(issuer)
        .setAudience(DEVICE_AUDIENCE)
        .setIssuedAt(nowSeconds)
        .setExpirationTime(nowSeconds + ttlSeconds)
        .sign(signingKey);
    },

    async verifySession(token) {
      const { payload } = await jwtVerify(String(token), signingKey, {
        algorithms: ["HS256"],
        issuer,
        audience: DEVICE_AUDIENCE,
        currentDate: now(),
      });
      if (payload.kind !== "device" || typeof payload.sub !== "string" || payload.sub.length === 0) {
        throw new Error("Not a device session token");
      }
      return { sub: payload.sub, expiresAt: payload.exp };
    },

    pendingChallengeCount() {
      pruneChallenges();
      return pendingChallenges.size;
    },
  };
}
