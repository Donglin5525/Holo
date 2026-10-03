// Apple refresh token 加密留存（2026-10-04 体检 P02）。
//
// TN3194：账号删除必须撤销 Sign in with Apple 凭证，撤销接口只认 access/refresh
// token——授权码换来的 refresh_token 是唯一可长期持有的撤销凭证。本模块把它
// 以 AES-256-GCM 加密落库（apple_sub 主键，一账号一行，重登录覆盖）。
// 加密密钥未配置时宁可不入库（撤销退化为 REFRESH_TOKEN_UNAVAILABLE 引导），
// 也不落明文。删除撤销成功后即焚。
import { createCipheriv, createDecipheriv, createHash, randomBytes } from "node:crypto";

const FORMAT_PREFIX = "v1:";
const KEY_BYTES = 32;
const IV_BYTES = 12;

export function createAppleTokenStore(db, { encryptionKey } = {}) {
  const key = normalizeKey(encryptionKey);
  if (!key) {
    return {
      configured: false,
      async save() {
        return false;
      },
      lookup() {
        return null;
      },
      remove() {},
    };
  }

  return {
    configured: true,

    /// 授权码换得的 refresh token 加密入库（UPSERT：重登录覆盖旧凭证）
    save(appleSub, refreshToken) {
      db.prepare(
        `INSERT INTO apple_refresh_tokens (apple_sub, refresh_token, updated_at)
         VALUES (?, ?, CURRENT_TIMESTAMP)
         ON CONFLICT(apple_sub) DO UPDATE SET
           refresh_token = excluded.refresh_token,
           updated_at = CURRENT_TIMESTAMP`,
      ).run(appleSub, encrypt(refreshToken, key));
    },

    lookup(appleSub) {
      const row = db
        .prepare("SELECT refresh_token FROM apple_refresh_tokens WHERE apple_sub = ?")
        .get(appleSub);
      if (!row) return null;
      try {
        return decrypt(row.refresh_token, key);
      } catch {
        return null;
      }
    },

    remove(appleSub) {
      db.prepare("DELETE FROM apple_refresh_tokens WHERE apple_sub = ?").run(appleSub);
    },
  };
}

function normalizeKey(value) {
  const raw = String(value ?? "");
  if (!raw) return null;
  const asBase64 = Buffer.from(raw, "base64");
  if (asBase64.length === KEY_BYTES) return asBase64;
  // 非 32 字节 base64 的配置统一派生，避免「看起来配了实际没用」
  return createHash("sha256").update(raw, "utf8").digest();
}

function encrypt(plaintext, key) {
  const iv = randomBytes(IV_BYTES);
  const cipher = createCipheriv("aes-256-gcm", key, iv);
  const encrypted = Buffer.concat([cipher.update(String(plaintext), "utf8"), cipher.final()]);
  return FORMAT_PREFIX
    + iv.toString("base64") + ":"
    + cipher.getAuthTag().toString("base64") + ":"
    + encrypted.toString("base64");
}

function decrypt(payload, key) {
  const raw = String(payload);
  if (!raw.startsWith(FORMAT_PREFIX)) {
    throw new Error("Unknown apple refresh token payload format");
  }
  const [ivB64, tagB64, dataB64] = raw.slice(FORMAT_PREFIX.length).split(":");
  const decipher = createDecipheriv("aes-256-gcm", key, Buffer.from(ivB64, "base64"));
  decipher.setAuthTag(Buffer.from(tagB64, "base64"));
  return Buffer.concat([
    decipher.update(Buffer.from(dataB64, "base64")),
    decipher.final(),
  ]).toString("utf8");
}
