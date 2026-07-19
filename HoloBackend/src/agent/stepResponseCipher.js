import {
  createCipheriv,
  createDecipheriv,
  createHash,
  randomBytes,
} from "node:crypto";

const ALGORITHM = "aes-256-gcm";
const FORMAT_PREFIX = "holo-agent-step:v1:";
const KEY_BYTES = 32;
const IV_BYTES = 12;
const AUTH_TAG_BYTES = 16;
const developmentKey = randomBytes(KEY_BYTES).toString("base64");

export class AgentStepEncryptionError extends Error {
  constructor(code, message, options = {}) {
    super(message, options);
    this.name = "AgentStepEncryptionError";
    this.code = code;
  }
}

/**
 * Agent step 响应的应用层信封加密。
 *
 * - AES-256-GCM 同时保证机密性与完整性。
 * - runId / stepId / requestHash 作为 AAD，密文不能跨步骤调包。
 * - 第一把密钥用于新写入；previousKeys 仅用于解密旧记录并在启动时重包裹。
 */
export function createStepResponseCipher({
  primaryKey,
  previousKeys = [],
  allowEphemeral = false,
} = {}) {
  const effectivePrimaryKey = normalizeOptionalKey(primaryKey)
    ?? (allowEphemeral ? developmentKey : null);
  if (!effectivePrimaryKey) {
    throw new AgentStepEncryptionError(
      "AGENT_STEP_ENCRYPTION_KEY_MISSING",
      "Agent step 响应加密密钥未配置",
    );
  }

  const primary = parseKey(effectivePrimaryKey, "primaryKey");
  const keyring = new Map([[primary.id, primary.key]]);
  for (const [index, encodedKey] of normalizePreviousKeys(previousKeys).entries()) {
    const parsed = parseKey(encodedKey, `previousKeys[${index}]`);
    keyring.set(parsed.id, parsed.key);
  }

  return {
    algorithm: "aes-256-gcm-v1",
    activeKeyId: primary.id,

    isEncrypted(value) {
      return typeof value === "string" && value.startsWith(FORMAT_PREFIX);
    },

    needsRotation(value) {
      if (!this.isEncrypted(value)) return true;
      return parseEnvelope(value).keyId !== primary.id;
    },

    encrypt(plaintext, identity) {
      if (typeof plaintext !== "string") {
        throw new AgentStepEncryptionError(
          "AGENT_STEP_ENCRYPTION_INVALID_PLAINTEXT",
          "Agent step 响应加密输入必须是字符串",
        );
      }
      const iv = randomBytes(IV_BYTES);
      const cipher = createCipheriv(ALGORITHM, primary.key, iv, {
        authTagLength: AUTH_TAG_BYTES,
      });
      cipher.setAAD(buildAAD(identity));
      const encrypted = Buffer.concat([
        cipher.update(plaintext, "utf8"),
        cipher.final(),
      ]);
      const authTag = cipher.getAuthTag();
      return [
        "holo-agent-step",
        "v1",
        primary.id,
        iv.toString("base64url"),
        authTag.toString("base64url"),
        encrypted.toString("base64url"),
      ].join(":");
    },

    decrypt(envelope, identity) {
      const parsed = parseEnvelope(envelope);
      const key = keyring.get(parsed.keyId);
      if (!key) {
        throw new AgentStepEncryptionError(
          "AGENT_STEP_ENCRYPTION_KEY_UNAVAILABLE",
          "Agent step 响应所需的解密密钥不可用",
        );
      }
      try {
        const decipher = createDecipheriv(ALGORITHM, key, parsed.iv, {
          authTagLength: AUTH_TAG_BYTES,
        });
        decipher.setAAD(buildAAD(identity));
        decipher.setAuthTag(parsed.authTag);
        return Buffer.concat([
          decipher.update(parsed.ciphertext),
          decipher.final(),
        ]).toString("utf8");
      } catch (error) {
        throw new AgentStepEncryptionError(
          "AGENT_STEP_ENCRYPTION_AUTH_FAILED",
          "Agent step 响应密文认证失败",
          { cause: error },
        );
      }
    },
  };
}

function normalizeOptionalKey(value) {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed || null;
}

function normalizePreviousKeys(value) {
  if (Array.isArray(value)) {
    return value.map(normalizeOptionalKey).filter(Boolean);
  }
  if (typeof value === "string") {
    return value.split(",").map(normalizeOptionalKey).filter(Boolean);
  }
  return [];
}

function parseKey(encodedKey, label) {
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(encodedKey)) {
    throw invalidKey(label);
  }
  const key = Buffer.from(encodedKey, "base64");
  const canonical = key.toString("base64");
  if (key.length !== KEY_BYTES || canonical !== encodedKey) {
    throw invalidKey(label);
  }
  return {
    id: createHash("sha256").update(key).digest("hex").slice(0, 16),
    key,
  };
}

function invalidKey(label) {
  return new AgentStepEncryptionError(
    "AGENT_STEP_ENCRYPTION_KEY_INVALID",
    `${label} 必须是 32 字节密钥的标准 Base64 编码`,
  );
}

function buildAAD(identity) {
  const runId = identity?.runId;
  const stepId = identity?.stepId;
  const requestHash = identity?.requestHash;
  if (![runId, stepId, requestHash].every((value) => typeof value === "string" && value)) {
    throw new AgentStepEncryptionError(
      "AGENT_STEP_ENCRYPTION_IDENTITY_INVALID",
      "Agent step 响应加密缺少稳定步骤身份",
    );
  }
  return Buffer.from(JSON.stringify([runId, stepId, requestHash]), "utf8");
}

function parseEnvelope(value) {
  if (typeof value !== "string" || !value.startsWith(FORMAT_PREFIX)) {
    throw new AgentStepEncryptionError(
      "AGENT_STEP_ENCRYPTION_FORMAT_INVALID",
      "Agent step 响应密文格式无效",
    );
  }
  const parts = value.split(":");
  if (parts.length !== 6 || parts[0] !== "holo-agent-step" || parts[1] !== "v1") {
    throw new AgentStepEncryptionError(
      "AGENT_STEP_ENCRYPTION_FORMAT_INVALID",
      "Agent step 响应密文格式无效",
    );
  }
  try {
    const iv = Buffer.from(parts[3], "base64url");
    const authTag = Buffer.from(parts[4], "base64url");
    const ciphertext = Buffer.from(parts[5], "base64url");
    if (iv.length !== IV_BYTES || authTag.length !== AUTH_TAG_BYTES || ciphertext.length === 0) {
      throw new Error("invalid envelope lengths");
    }
    return {
      keyId: parts[2],
      iv,
      authTag,
      ciphertext,
    };
  } catch (error) {
    throw new AgentStepEncryptionError(
      "AGENT_STEP_ENCRYPTION_FORMAT_INVALID",
      "Agent step 响应密文格式无效",
      { cause: error },
    );
  }
}
