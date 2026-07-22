export async function closeHttpServer(server, { timeoutMs = 10_000 } = {}) {
  await new Promise((resolve, reject) => {
    let settled = false;
    const finish = (error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      if (error) reject(error);
      else resolve();
    };
    const timeout = setTimeout(() => {
      server.closeAllConnections?.();
      finish(new Error(`HTTP server 关闭超时（${timeoutMs}ms）`));
    }, timeoutMs);
    timeout.unref?.();
    server.close(finish);
  });
}
