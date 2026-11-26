#!/usr/bin/env node
// 想法主题归类评测 · 人工标注页（方案 P0.2）
//
// 用法（二选一）：
//   node scripts/thought-topic-eval/make-label-sheet.mjs --results <Holo独立整理的结果.json> [--sample 200]
//       主题清单 = Holo 自己整理出来的主题；不预勾任何东西，也不显示 Holo 的归类结果（盲标）。
//   node scripts/thought-topic-eval/make-label-sheet.mjs --dataset <数据集.json> --set dev [--sample 200]
//       主题清单 = 数据集自带的；数据集自带的答案预先勾上。
//
// 按时间三等分各抽同样多的想法，总数正好是 --sample（默认 200），生成一个单文件网页（本地双击打开，
// 不联网）：每条显示正文 + 全部主题的勾选框（最多 3 个）+「都不该放」+「拿不准」+ 可选的「该单独成什么主题」。
// 勾选随时存在浏览器本地；右上角「导出」得到 gold.json，交给 rescore.mjs 评分。
// 网页里是真实想法正文，只能写在已 gitignore 的 eval/private/ 下。

import { readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

import { parseArgs } from "./lib/args.mjs";
import { loadDataset } from "./lib/dataset.mjs";
import { PRIVATE_DIR, assertGitIgnored } from "./lib/paths.mjs";

const DEFAULT_SAMPLE = 200;

/** 稳定随机：同一条命令每次抽到同一批，中断后重新生成还能接着标。 */
function seededRandom(seedText) {
  let hash = 2166136261;
  for (const byte of Buffer.from(seedText, "utf8")) hash = Math.imul(hash ^ byte, 16777619);
  return () => {
    hash = (hash + 0x6d2b79f5) >>> 0;
    let value = hash;
    value = Math.imul(value ^ (value >>> 15), value | 1);
    value ^= value + Math.imul(value ^ (value >>> 7), value | 61);
    return ((value ^ (value >>> 14)) >>> 0) / 4294967296;
  };
}

function take(items, count, random) {
  const copy = [...items];
  for (let index = copy.length - 1; index > 0; index -= 1) {
    const swap = Math.floor(random() * (index + 1));
    [copy[index], copy[swap]] = [copy[swap], copy[index]];
  }
  return copy.slice(0, count);
}

function page(data) {
  // 正文走 textContent 写入；这里先把 JSON 里的 < 转义，防止正文提前结束 script
  const payload = JSON.stringify(data).replace(/</g, "\\u003c");
  const intro = data.preFilled
    ? "每条想法：看正文，勾选它<b>应该属于</b>哪些主题（最多 3 个）。原来的标签已经预先勾好，只需要把漏的补上、把不对的去掉。"
    : "每条想法：看正文，勾选你认为它<b>应该属于</b>哪些主题（最多 3 个）。下面的主题清单是 Holo 自己整理出来的；这里故意不显示 Holo 归到了哪，请按你自己的判断勾。如果它该成一个清单里没有的主题，在输入框里写个名字。";
  return `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>想法主题归类 · 标注</title>
<style>
  body { font-family: -apple-system, "PingFang SC", sans-serif; margin: 0; background: #fafafa; color: #222; }
  header { position: sticky; top: 0; z-index: 2; background: #fff; border-bottom: 1px solid #e5e5e5; padding: 12px 20px; display: flex; gap: 16px; align-items: center; flex-wrap: wrap; }
  header h1 { font-size: 16px; margin: 0; }
  header .status { font-size: 13px; color: #666; }
  header .actions { margin-left: auto; display: flex; gap: 8px; }
  button { font: inherit; font-size: 13px; padding: 6px 12px; border-radius: 8px; border: 1px solid #ccc; background: #fff; cursor: pointer; }
  button.primary { background: #222; color: #fff; border-color: #222; }
  main { max-width: 760px; margin: 0 auto; padding: 16px 20px 80px; }
  .intro { font-size: 13px; color: #555; line-height: 1.7; margin-bottom: 14px; }
  .card { background: #fff; border: 1px solid #e5e5e5; border-radius: 12px; padding: 16px; margin-bottom: 14px; }
  .card.changed { border-color: #d9a441; }
  .meta { font-size: 12px; color: #888; margin-bottom: 8px; }
  .meta .tag { color: #a9771a; }
  .text { white-space: pre-wrap; line-height: 1.7; font-size: 15px; max-height: 340px; overflow-y: auto; }
  .topics { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 12px; }
  label { font-size: 13px; border: 1px solid #ddd; border-radius: 999px; padding: 4px 10px; cursor: pointer; user-select: none; }
  label input { margin-right: 4px; }
  label.on { background: #222; color: #fff; }
  label.flag { border-style: dashed; }
  .suggest { margin-top: 10px; font-size: 13px; color: #666; display: flex; gap: 8px; align-items: center; }
  .suggest input { font: inherit; flex: 1; padding: 4px 8px; border: 1px solid #ddd; border-radius: 8px; }
  #hint { font-size: 12px; color: #a9771a; min-height: 16px; }
</style>
</head>
<body>
<header>
  <h1>想法主题归类 · 标注</h1>
  <span class="status" id="status"></span>
  <span class="actions">
    <button id="import-button">导入</button><input type="file" id="import" accept="application/json" hidden>
    <button id="reset">清空改动</button>
    <button id="export" class="primary">导出 gold.json</button>
  </span>
</header>
<main>
  <p class="intro">${intro}
  一条都不属于就只留「都不该放」；实在判断不了勾「拿不准」（这条不计分）。改动随时保存在这台电脑的浏览器里，标完点右上角「导出」。</p>
  <div id="hint"></div>
  <div id="notes"></div>
</main>
<script type="application/json" id="data">${payload}</script>
<script>
  const DATA = JSON.parse(document.getElementById("data").textContent);
  const notesEl = document.getElementById("notes");
  const statusEl = document.getElementById("status");
  const hintEl = document.getElementById("hint");
  const state = JSON.parse(localStorage.getItem(DATA.storeKey) || "{}");
  const save = () => localStorage.setItem(DATA.storeKey, JSON.stringify(state));
  const valueOf = (note) => state[note.id] ?? { topicIds: note.defaults, unsure: false, suggest: "" };
  const escapeHtml = (text) => String(text).replace(/[&<>"]/g, (ch) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[ch]);

  function render() {
    notesEl.innerHTML = DATA.notes.map((note, index) => {
      const value = valueOf(note);
      const topics = DATA.topics.map((topic) =>
        '<label class="' + (value.topicIds.includes(topic.id) ? "on" : "") + '"><input type="checkbox" data-topic="' + topic.id + '">' + escapeHtml(topic.title) + "</label>").join("");
      return '<article class="card' + (state[note.id] ? " changed" : "") + '" data-id="' + note.id + '">'
        + '<div class="meta">' + (index + 1) + " / " + DATA.notes.length + "　" + note.date + (state[note.id] ? '　<span class="tag">已标</span>' : "") + "</div>"
        + '<div class="text"></div>'
        + '<div class="topics"><label class="flag' + (value.topicIds.length === 0 && !value.unsure ? " on" : "") + '"><input type="checkbox" data-flag="none">都不该放</label>' + topics
        + '<label class="flag' + (value.unsure ? " on" : "") + '"><input type="checkbox" data-flag="unsure">拿不准</label></div>'
        + '<div class="suggest">该单独成一个主题：<input type="text" data-suggest maxlength="30" placeholder="可留空"></div></article>';
    }).join("");
    DATA.notes.forEach((note) => {
      const card = notesEl.querySelector('[data-id="' + note.id + '"]');
      card.querySelector(".text").textContent = note.text;
      card.querySelector("[data-suggest]").value = valueOf(note).suggest ?? "";
    });
    statusEl.textContent = "已标 " + Object.keys(state).length + " / " + DATA.notes.length + " 条";
  }

  function current(input) {
    const id = input.closest(".card").dataset.id;
    const note = DATA.notes.find((item) => item.id === id);
    const base = valueOf(note);
    return { id, value: { topicIds: [...base.topicIds], unsure: base.unsure, suggest: base.suggest ?? "" } };
  }

  notesEl.addEventListener("change", (event) => {
    const input = event.target;
    if (input.dataset.topic === undefined && input.dataset.flag === undefined) return;
    const { id, value } = current(input);
    hintEl.textContent = "";
    if (input.dataset.flag === "none") {
      value.topicIds = [];
      value.unsure = false;
    } else if (input.dataset.flag === "unsure") {
      value.unsure = input.checked;
      if (input.checked) value.topicIds = [];
    } else if (input.checked) {
      if (value.topicIds.length >= 3) {
        input.checked = false;
        hintEl.textContent = "一条想法最多勾 3 个主题；要加新的，先取消一个。";
        return;
      }
      value.unsure = false;
      value.topicIds.push(input.dataset.topic);
    } else {
      value.topicIds = value.topicIds.filter((topicId) => topicId !== input.dataset.topic);
    }
    state[id] = value;
    save();
    render();
  });

  notesEl.addEventListener("input", (event) => {
    if (event.target.dataset.suggest === undefined) return;
    const { id, value } = current(event.target);
    value.suggest = event.target.value;
    state[id] = value;
    save();
    statusEl.textContent = "已标 " + Object.keys(state).length + " / " + DATA.notes.length + " 条";
  });

  document.getElementById("export").addEventListener("click", () => {
    const gold = {
      formatVersion: 1,
      source: DATA.source,
      exportedAt: new Date().toISOString(),
      labels: DATA.notes.map((note) => {
        const value = valueOf(note);
        return { thoughtId: note.id, topicIds: value.topicIds, unsure: value.unsure, suggest: value.suggest ?? "" };
      }),
    };
    const url = URL.createObjectURL(new Blob([JSON.stringify(gold, null, 1)], { type: "application/json" }));
    const link = document.createElement("a");
    link.href = url;
    link.download = "gold-" + DATA.source + ".json";
    link.click();
    URL.revokeObjectURL(url);
  });

  document.getElementById("import-button").addEventListener("click", () => document.getElementById("import").click());
  document.getElementById("import").addEventListener("change", async (event) => {
    const file = event.target.files[0];
    if (!file) return;
    for (const label of JSON.parse(await file.text()).labels ?? []) {
      state[label.thoughtId] = { topicIds: label.topicIds, unsure: label.unsure === true, suggest: label.suggest ?? "" };
    }
    save();
    render();
  });

  document.getElementById("reset").addEventListener("click", () => {
    if (!confirm("清空全部改动？")) return;
    for (const key of Object.keys(state)) delete state[key];
    save();
    render();
  });

  render();
</script>
</body>
</html>
`;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const sampleSize = Number(args.sample ?? DEFAULT_SAMPLE);
  let source;
  if (args.results !== undefined) {
    const results = JSON.parse(readFileSync(resolve(args.results), "utf8"));
    source = {
      name: results.meta.tag,
      preFilled: false,
      notes: results.thoughts
        .filter((record) => record.text.trim().length > 0)
        .map((record) => ({ id: record.id, createdAtMs: Date.parse(record.createdAt), text: record.text, defaults: [] })),
      topics: results.topicDetails
        .map((topic) => ({ id: topic.id, title: topic.title, members: topic.members }))
        .sort((a, b) => b.members - a.members || a.title.localeCompare(b.title)),
    };
  } else {
    if (args.dataset === undefined || args.set === undefined) {
      console.log("用法：make-label-sheet.mjs --results <结果.json> [--sample 200]  或  --dataset <数据集.json> --set dev|holdout [--sample 200]");
      process.exit(1);
    }
    const dataset = await loadDataset(resolve(args.dataset));
    const members = new Map();
    for (const thought of dataset.thoughts) {
      for (const topicId of thought.gold?.topicIds ?? []) members.set(topicId, (members.get(topicId) ?? 0) + 1);
    }
    source = {
      name: `${dataset.name}-${args.set}`,
      preFilled: true,
      notes: dataset.thoughts
        .filter((thought) => thought.gold !== null && thought.split === args.set)
        .map((thought) => ({ id: thought.id, createdAtMs: thought.createdAtMs, text: thought.text, defaults: thought.gold.topicIds })),
      topics: [...dataset.topics.values()]
        .map((topic) => ({ id: topic.id, title: topic.title, members: members.get(topic.id) ?? 0 }))
        .sort((a, b) => b.members - a.members || a.title.localeCompare(b.title)),
    };
  }
  if (source.notes.length === 0) throw new Error("没有可标注的想法");

  // 按时间三等分，各段抽同样多，总数正好是 sampleSize（200 → 67 / 67 / 66）
  const ordered = source.notes.slice().sort((a, b) => a.createdAtMs - b.createdAtMs);
  const third = Math.ceil(ordered.length / 3);
  const random = seededRandom(`label:${source.name}`);
  const sizes = [0, 1, 2].map((stratum) => Math.floor(sampleSize / 3) + (stratum < sampleSize % 3 ? 1 : 0));
  const strata = sizes.map((size, stratum) => take(ordered.slice(stratum * third, (stratum + 1) * third), size, random));
  const selected = strata.flat().sort((a, b) => b.createdAtMs - a.createdAtMs);

  const data = {
    source: source.name,
    preFilled: source.preFilled,
    storeKey: `thought-topic-gold:${source.name}`,
    topics: source.topics,
    notes: selected.map((note) => ({
      id: note.id,
      date: new Date(note.createdAtMs).toISOString().slice(0, 10),
      text: note.text,
      defaults: note.defaults,
    })),
  };
  const outPath = join(PRIVATE_DIR, `label-${source.name}.html`);
  assertGitIgnored(outPath);
  writeFileSync(outPath, page(data));
  console.log(`标注页已生成：${outPath}`);
  console.log(`  共 ${selected.length} 条（时间早 / 中 / 近三段：${strata.map((stratum) => stratum.length).join(" / ")}）| 可选主题 ${source.topics.length} 个${source.preFilled ? "（原标签已预勾）" : "（盲标，不预勾）"}`);
  console.log(`  最远 ${data.notes.at(-1)?.date} ～ 最近 ${data.notes[0]?.date}；文件只放在私有目录，不会入库。`);
}

main().catch((error) => {
  console.error("生成标注页失败:", error.message);
  process.exit(1);
});
