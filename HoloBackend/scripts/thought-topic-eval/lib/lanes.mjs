// 想法主题归类评测 · 多通道并行
//
// 后端按设备号限流（每分钟 20 次）。要提速就多开通道：每条通道用自己的设备号，
// 互不占额度；同一条通道内按顺序执行。
// 任何一条任务抛错（如费用护栏拦截）即整场停下：其余通道做完手上这条就收工，不再领新任务。

export async function runLanes(items, laneCount, worker) {
  let cursor = 0;
  let firstError = null;
  const lane = async (laneIndex) => {
    while (firstError === null) {
      const index = cursor;
      cursor += 1;
      if (index >= items.length) return;
      try {
        await worker(items[index], laneIndex);
      } catch (error) {
        if (firstError === null) firstError = error;
        return;
      }
    }
  };
  const width = Math.max(1, Math.min(laneCount, items.length));
  await Promise.all(Array.from({ length: width }, (_, laneIndex) => lane(laneIndex)));
  if (firstError !== null) throw firstError;
}
