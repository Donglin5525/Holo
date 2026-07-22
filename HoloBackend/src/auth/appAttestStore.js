import { createHash, randomBytes } from "node:crypto";

const DEFAULT_CHALLENGE_TTL_SECONDS = 5 * 60;

export function createAppAttestStore(db, options = {}) {
  const now = options.now ?? (() => new Date());
  const challengeTtlSeconds = Number(
    options.challengeTtlSeconds ?? DEFAULT_CHALLENGE_TTL_SECONDS,
  );

  const insertChallenge = db.prepare(`
    INSERT INTO app_attest_challenges (id, challenge_hash, key_id, expires_at, consumed_at)
    VALUES (?, ?, ?, ?, NULL)
  `);
  const consumeChallenge = db.prepare(`
    UPDATE app_attest_challenges
    SET consumed_at = ?
    WHERE id = ?
      AND challenge_hash = ?
      AND (key_id IS NULL OR key_id = ?)
      AND consumed_at IS NULL
      AND expires_at >= ?
  `);
  const getKey = db.prepare(`
    SELECT key_id, public_key_pem, receipt, sign_count, environment, created_at, last_seen_at
    FROM app_attest_keys
    WHERE key_id = ?
  `);
  const insertKey = db.prepare(`
    INSERT INTO app_attest_keys (
      key_id, public_key_pem, receipt, sign_count, environment, created_at, last_seen_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?)
  `);
  const updateCounter = db.prepare(`
    UPDATE app_attest_keys
    SET sign_count = ?, last_seen_at = ?
    WHERE key_id = ? AND sign_count = ?
  `);
  const purgeChallenges = db.prepare(`
    DELETE FROM app_attest_challenges
    WHERE expires_at < ? OR consumed_at IS NOT NULL
  `);

  return {
    createChallenge(keyId = null) {
      // 挑战仅短期有效；在创建新挑战时顺手回收已消费/过期记录，避免表无限增长。
      purgeChallenges.run(Math.floor(now().getTime() / 1000));
      const challenge = randomBytes(32).toString("base64url");
      const id = randomBytes(16).toString("base64url");
      const nowSeconds = Math.floor(now().getTime() / 1000);
      const expiresAt = nowSeconds + challengeTtlSeconds;
      insertChallenge.run(
        id,
        sha256Hex(challenge),
        normalizeOptionalKeyId(keyId),
        expiresAt,
      );
      return { id, challenge, expiresAt, expiresInSeconds: challengeTtlSeconds };
    },

    consumeChallenge({ id, challenge, keyId }) {
      const nowSeconds = Math.floor(now().getTime() / 1000);
      const result = consumeChallenge.run(
        nowSeconds,
        String(id ?? ""),
        sha256Hex(String(challenge ?? "")),
        String(keyId ?? ""),
        nowSeconds,
      );
      return result.changes === 1;
    },

    registerKey({ keyId, publicKeyPem, receipt = null, environment, signCount = 0 }) {
      const nowSeconds = Math.floor(now().getTime() / 1000);
      insertKey.run(
        keyId,
        publicKeyPem,
        receipt,
        signCount,
        environment,
        nowSeconds,
        nowSeconds,
      );
    },

    getKey(keyId) {
      const row = getKey.get(keyId);
      if (!row) return null;
      return {
        keyId: row.key_id,
        publicKeyPem: row.public_key_pem,
        receipt: row.receipt,
        signCount: row.sign_count,
        environment: row.environment,
        createdAt: row.created_at,
        lastSeenAt: row.last_seen_at,
      };
    },

    advanceCounter({ keyId, previousCounter, nextCounter }) {
      if (!Number.isInteger(nextCounter) || nextCounter <= previousCounter) return false;
      const result = updateCounter.run(
        nextCounter,
        Math.floor(now().getTime() / 1000),
        keyId,
        previousCounter,
      );
      return result.changes === 1;
    },

    purgeExpiredChallenges() {
      return purgeChallenges.run(Math.floor(now().getTime() / 1000)).changes;
    },
  };
}

function sha256Hex(value) {
  return createHash("sha256").update(value, "utf8").digest("hex");
}

function normalizeOptionalKeyId(value) {
  if (value === undefined || value === null || value === "") return null;
  return String(value);
}
