import "dotenv/config";
import { serve } from "@hono/node-server";
import { createDatabase } from "./db/database.js";
import { closeHttpServer } from "./gracefulShutdown.js";

const port = Number(process.env.PORT ?? 8787);

const dbPath = process.env.HOLO_DB_PATH ?? "/data/holo-backend.db";
let database;
try {
  database = createDatabase({ dbPath });
  console.log(`[DB] SQLite 数据库已初始化: ${dbPath}`);
} catch (err) {
  console.error(`[DB] 数据库初始化失败: ${err.message}`);
  process.exit(1);
}

const { createApp } = await import("./app.js");
const app = createApp({ database });

const server = serve(
  {
    fetch: (req, env, ctx) => app.fetch(req, env, ctx),
    port,
  },
  (info) => {
    console.log(`Holo AI Gateway listening on http://localhost:${info.port}`);
  },
);

let shuttingDown = false;
async function gracefulShutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  console.log(`\n[${signal}] 正在关闭...`);
  let exitCode = 0;
  try {
    await closeHttpServer(server, { timeoutMs: 10_000 });
    app.shutdown?.();
    database.close();
    console.log("[DB] 数据库已关闭");
  } catch (error) {
    exitCode = 1;
    console.error(`[Shutdown] ${error.message}`);
    app.shutdown?.();
    try { database.close(); } catch {}
  }
  process.exitCode = exitCode;
}

process.on("SIGINT", () => gracefulShutdown("SIGINT"));
process.on("SIGTERM", () => gracefulShutdown("SIGTERM"));
