/**
 * Agent 遥测事件存储（SQLite）
 * - iOS 端 HoloAgentEventStore 的服务端落地：锁屏租约、执行恢复、任务终态等
 *   结构化诊断事件在设备联网时批量上报（2026-08-30 锁屏事故：关键证据全部
 *   只存手机本地，远端一片空白，排查只能靠推演）。
 * - 主键 id = 客户端事件 UUID：上报失败重试 INSERT OR IGNORE 幂等去重。
 * - 仅技术字段（状态/计数/稳定错误码），与 iOS 端隐私契约一致：不收用户
 *   问题、消息正文、工具结果；入库前由端点做字段白名单与长度截断。
 * - 与 iOS 本地环形仓库同款 14 天滚动保留，写入时顺手清理过期行。
 */

const RETENTION_MS = 14 * 24 * 60 * 60 * 1000;

export function createAgentTelemetryStore(db) {
  const insertStmt = db.prepare(`
    INSERT OR IGNORE INTO agent_telemetry_events (
      id, device_id, name, timestamp_ms, job_id, job_type, trigger, state,
      wait_reason, generation, checkpoint_revision, lease_kind, round,
      duration_ms, error_code, request_id, prompt_revision,
      agent_protocol_version, tool_schema_version,
      contract_violation_count, contract_repair_count, received_at_ms
    ) VALUES (
      @id, @device_id, @name, @timestamp_ms, @job_id, @job_type, @trigger, @state,
      @wait_reason, @generation, @checkpoint_revision, @lease_kind, @round,
      @duration_ms, @error_code, @request_id, @prompt_revision,
      @agent_protocol_version, @tool_schema_version,
      @contract_violation_count, @contract_repair_count, @received_at_ms
    )
  `);
  const purgeStmt = db.prepare(`
    DELETE FROM agent_telemetry_events WHERE received_at_ms <= ?
  `);
  const countStmt = db.prepare(`
    SELECT COUNT(*) AS total FROM agent_telemetry_events
  `);
  const listByJobStmt = db.prepare(`
    SELECT * FROM agent_telemetry_events
    WHERE job_id = ?
    ORDER BY timestamp_ms ASC
    LIMIT ?
  `);

  return {
    /** 批量写入；返回实际新增条数（重复 id 不计） */
    insertBatch(deviceId, events, now = Date.now()) {
      const rows = events.map((event) => ({
        id: event.id,
        device_id: deviceId,
        name: event.name,
        timestamp_ms: event.timestampMs,
        job_id: event.jobID ?? null,
        job_type: event.jobType ?? null,
        trigger: event.trigger ?? null,
        state: event.state ?? null,
        wait_reason: event.waitReason ?? null,
        generation: event.generation ?? null,
        checkpoint_revision: event.checkpointRevision ?? null,
        lease_kind: event.leaseKind ?? null,
        round: event.round ?? null,
        duration_ms: event.durationMilliseconds ?? null,
        error_code: event.errorCode ?? null,
        request_id: event.requestID ?? null,
        prompt_revision: event.promptRevision ?? null,
        agent_protocol_version: event.agentProtocolVersion ?? null,
        tool_schema_version: event.toolSchemaVersion ?? null,
        contract_violation_count: event.contractViolationCount ?? null,
        contract_repair_count: event.contractRepairCount ?? null,
        received_at_ms: now,
      }));
      const write = db.transaction(() => {
        let inserted = 0;
        for (const row of rows) {
          inserted += insertStmt.run(row).changes;
        }
        return inserted;
      });
      const inserted = write();
      purgeStmt.run(now - RETENTION_MS);
      return inserted;
    },

    count() {
      return countStmt.get().total;
    },

    listByJob(jobId, limit = 200) {
      return listByJobStmt.all(jobId, limit);
    },
  };
}
