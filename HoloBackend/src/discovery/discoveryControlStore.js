import { createHash, randomUUID } from "node:crypto";
import { GatewayError } from "../errors.js";
import { shanghaiDateString } from "../usage/quotaPolicy.js";

/**
 * 「一个发现」控制存储（实施包 03 §3.2、决策表·账号主体拍板）。
 *
 * 账号主体 = backgroundSubject(deviceId, entitlement)（购买合并口径：
 * sha256(purchase:{env}:{originalTransactionId})，无交易退化为 sha256(device:{deviceId})），
 * 由服务端从已验证设备导出，body 自报身份一律不信任。
 *
 * 已知限制（有意接受，写入交付报告）：免费/无共享购买的双设备 = 两个主体 = 两个
 * 独立批次预算；同主体内的多设备单 owner 语义仍由本 store 保证。
 *
 * CAS 撤权语义：
 * - enable/scope 必须携 expectedRevision，不符 → 409（旧 grant 读取的版本已失效）；
 * - 单 owner：已启用时其他设备 enable 必须显式 confirmTakeover 才能接管，revision+1；
 * - disable 任一（同主体）已验证设备可发，保守覆盖：无条件 enabled=0 + revision+1，
 *   不按客户端时钟判新旧；旧 enable 重放因 expectedRevision 过期不能复活（T13）；
 * - 全部控制操作经 discovery_requests 幂等：同 requestId 同 hash 重放返回同结果，
 *   同 requestId 不同 hash → 409（T16）。
 */

export const DISCOVERY_ALLOWED_DOMAINS = Object.freeze(["thought", "task", "habit"]);

export function createDiscoveryControlStore(db, options = {}) {
  const now = options.now ?? (() => Date.now());
  const leaseMs = Number(options.leaseMs ?? 10 * 60_000);

  const getControl = db.prepare("SELECT * FROM discovery_controls WHERE subject = ?");
  const insertControl = db.prepare(`
    INSERT INTO discovery_controls
      (subject, enabled, revision, owner_device_id, scope_revision, allowed_domains, consent_doc_version, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  `);
  const updateEnable = db.prepare(`
    UPDATE discovery_controls SET enabled = 1, revision = ?, owner_device_id = ?,
      scope_revision = scope_revision + 1, allowed_domains = ?, consent_doc_version = ?, updated_at = ?
    WHERE subject = ? AND revision = ?
  `);
  const updateScopeRow = db.prepare(`
    UPDATE discovery_controls SET revision = revision + 1, scope_revision = scope_revision + 1,
      allowed_domains = ?, consent_doc_version = ?, updated_at = ?
    WHERE subject = ? AND revision = ? AND enabled = 1
  `);
  const updateDisable = db.prepare(`
    UPDATE discovery_controls SET enabled = 0, revision = revision + 1, owner_device_id = owner_device_id,
      updated_at = ?
    WHERE subject = ? AND revision = ?
  `);

  const getRequest = db.prepare("SELECT * FROM discovery_requests WHERE request_id = ?");
  const insertRequest = db.prepare(`
    INSERT INTO discovery_requests (request_id, subject, kind, request_hash, status, result_meta, created_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  `);

  const shanghaiDay = () => shanghaiDateString(new Date(now()));

  /** 读控制快照（无行时返回默认 disabled/revision=0）。 */
  function get(subject) {
    const row = getControl.get(subject);
    if (!row) {
      return {
        subject, enabled: false, revision: 0, ownerDeviceId: null,
        scopeRevision: 0, allowedDomains: [...DISCOVERY_ALLOWED_DOMAINS],
        consentDocVersion: null, updatedAt: null,
      };
    }
    return {
      subject: row.subject,
      enabled: row.enabled === 1,
      revision: row.revision,
      ownerDeviceId: row.owner_device_id,
      scopeRevision: row.scope_revision,
      allowedDomains: parseDomains(row.allowed_domains),
      consentDocVersion: row.consent_doc_version,
      updatedAt: row.updated_at,
    };
  }

  /**
   * 开启（CAS + 单 owner 接管）。
   * @returns {{ control, grant: {deviceId, revision, scopeRevision, dayKey, leaseExpiresAt} }}
   */
  function enable({ subject, deviceId, expectedRevision, allowedDomains, consentDocVersion, confirmTakeover, requestId }) {
    const domains = normalizeDomains(allowedDomains);
    const requestHash = controlRequestHash("enable", { expectedRevision, domains, consentDocVersion, confirmTakeover });
    const replay = replayOrThrow({ requestId, subject, kind: "enable", requestHash });
    // 幂等重放（含「旧 enable 重放不复活」场景）：只返回首次登记结果，不重放任何写动作
    if (replay) {
      return { control: get(subject), grant: replay.result, replayed: true };
    }

    const current = get(subject);
    if (current.revision !== expectedRevision) {
      throw new GatewayError("DISCOVERY_REVISION_CONFLICT", "Control revision mismatch", 409, {
        currentRevision: current.revision,
      });
    }
    if (current.enabled && current.ownerDeviceId && current.ownerDeviceId !== deviceId && !confirmTakeover) {
      throw new GatewayError("DISCOVERY_TAKEOVER_REQUIRED", "Another device owns auto preparation", 409, {
        ownerDeviceId: current.ownerDeviceId,
      });
    }

    const ts = now();
    const nextRevision = current.revision + 1;
    const grant = {
      deviceId, revision: nextRevision, scopeRevision: current.enabled ? current.scopeRevision + 1 : 1,
      dayKey: shanghaiDay(), leaseExpiresAt: ts + leaseMs,
    };
    const tx = db.transaction(() => {
      if (!getControl.get(subject)) {
        insertControl.run(subject, 1, nextRevision, deviceId, grant.scopeRevision, JSON.stringify(domains), consentDocVersion ?? null, ts);
      } else {
        const changed = updateEnable.run(nextRevision, deviceId, JSON.stringify(domains), consentDocVersion ?? null, ts, subject, current.revision);
        if (changed.changes !== 1) {
          throw new GatewayError("DISCOVERY_REVISION_CONFLICT", "Control revision mismatch", 409, {
            currentRevision: get(subject).revision,
          });
        }
      }
      insertRequest.run(requestId, subject, "enable", requestHash, "committed",
        JSON.stringify(grant), ts, ts);
    });
    tx();

    return { control: get(subject), grant, replayed: false };
  }

  /** 关闭：任一同主体已验证设备可发；保守覆盖，序列单调；requestId 幂等。 */
  function disable({ subject, requestId, reason }) {
    const requestHash = controlRequestHash("disable", { reason: reason ?? null });
    const replay = replayOrThrow({ requestId, subject, kind: "disable", requestHash });
    if (replay) return { control: get(subject), replayed: true };

    const current = get(subject);
    const ts = now();
    const tx = db.transaction(() => {
      if (!getControl.get(subject)) {
        insertControl.run(subject, 0, current.revision + 1, null, 0, JSON.stringify([...DISCOVERY_ALLOWED_DOMAINS]), null, ts);
      } else {
        updateDisable.run(ts, subject, current.revision);
      }
      insertRequest.run(requestId, subject, "disable", requestHash, "committed",
        JSON.stringify({ revision: get(subject).revision }), ts, ts);
    });
    tx();
    return { control: get(subject), replayed: false };
  }

  /** 范围更新：CAS 递增 scopeRevision + revision，旧运行按版本失效。 */
  function updateScope({ subject, deviceId, expectedRevision, allowedDomains, consentDocVersion, requestId }) {
    const domains = normalizeDomains(allowedDomains);
    const requestHash = controlRequestHash("scope", { expectedRevision, domains, consentDocVersion });
    const replay = replayOrThrow({ requestId, subject, kind: "scope", requestHash });
    if (replay) return { control: get(subject), replayed: true };

    const current = get(subject);
    if (!current.enabled) {
      throw new GatewayError("DISCOVERY_CONTROL_DISABLED", "Discovery is not enabled", 409);
    }
    if (current.revision !== expectedRevision) {
      throw new GatewayError("DISCOVERY_REVISION_CONFLICT", "Control revision mismatch", 409, {
        currentRevision: current.revision,
      });
    }
    const ts = now();
    const tx = db.transaction(() => {
      const changed = updateScopeRow.run(JSON.stringify(domains), consentDocVersion ?? null, ts, subject, current.revision);
      if (changed.changes !== 1) {
        throw new GatewayError("DISCOVERY_REVISION_CONFLICT", "Control revision mismatch", 409, {
          currentRevision: get(subject).revision,
        });
      }
      insertRequest.run(requestId, subject, "scope", requestHash, "committed",
        JSON.stringify({ revision: get(subject).revision }), ts, ts);
    });
    tx();
    return { control: get(subject), replayed: false };
  }

  /**
   * 幂等键三态：新键返回 null；同键同 hash 返回 { result }（重放）；同键不同 hash 抛 409（T16）。
   */
  function replayOrThrow({ requestId, subject, kind, requestHash }) {
    const existing = getRequest.get(requestId);
    if (!existing) return null;
    if (existing.subject !== subject || existing.kind !== kind) {
      throw new GatewayError("DISCOVERY_REQUEST_CONFLICT", "Request id used for a different operation", 409);
    }
    if (existing.request_hash !== requestHash) {
      throw new GatewayError("DISCOVERY_REQUEST_CONFLICT", "Request id was used with a different payload", 409);
    }
    return { result: existing.result_meta ? JSON.parse(existing.result_meta) : null };
  }

  /** 通用幂等登记（阶段端点用）：同键同 hash 返回已存元数据，异 hash 抛 409。 */
  function recordRequest({ requestId, subject, kind, requestHash, status, resultMeta }) {
    const existing = getRequest.get(requestId);
    if (existing) {
      if (existing.subject !== subject || existing.kind !== kind) {
        throw new GatewayError("DISCOVERY_REQUEST_CONFLICT", "Request id used for a different operation", 409);
      }
      if (existing.request_hash !== requestHash) {
        throw new GatewayError("DISCOVERY_REQUEST_CONFLICT", "Request id was used with a different payload", 409);
      }
      return { replayed: true, result: existing.result_meta ? JSON.parse(existing.result_meta) : null };
    }
    const ts = now();
    try {
      insertRequest.run(requestId, subject, kind, requestHash, status ?? "committed",
        resultMeta ? JSON.stringify(resultMeta) : null, ts, ts);
    } catch (error) {
      // 并发下同键竞态：重读判定，仍按三态语义返回
      const raced = getRequest.get(requestId);
      if (!raced) throw error;
      if (raced.request_hash !== requestHash) {
        throw new GatewayError("DISCOVERY_REQUEST_CONFLICT", "Request id was used with a different payload", 409);
      }
      return { replayed: true, result: raced.result_meta ? JSON.parse(raced.result_meta) : null };
    }
    return { replayed: false, result: resultMeta ?? null };
  }

  return { get, enable, disable, updateScope, recordRequest, replayOrThrow };
}

function controlRequestHash(kind, payload) {
  return createHash("sha256")
    .update(JSON.stringify([kind, ...Object.keys(payload).sort().map((key) => payload[key])]))
    .digest("hex");
}

function normalizeDomains(domains) {
  const list = Array.isArray(domains) ? domains : [];
  if (list.length === 0) {
    throw new GatewayError("INVALID_REQUEST", "At least one source domain is required", 400);
  }
  const unique = [...new Set(list)];
  for (const domain of unique) {
    if (!DISCOVERY_ALLOWED_DOMAINS.includes(domain)) {
      throw new GatewayError("INVALID_REQUEST", `Unsupported domain: ${String(domain).slice(0, 32)}`, 400);
    }
  }
  return unique;
}

function parseDomains(raw) {
  try {
    const parsed = JSON.parse(raw ?? "[]");
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

/** 生成服务端幂等键（客户端未传 requestId 时；控制操作要求客户端传，此处兜底防漏） */
export function fallbackRequestId() {
  return randomUUID();
}
