// 想法主题归类评测 · 目录约定
//
// eval/               只放可入库的东西（聚合数字的报告、向量文件）
// eval/private/       真实正文、金标标注、含正文的结果——已在根 .gitignore，写前再校验一次

import { execFileSync } from "node:child_process";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));

export const REPO_ROOT = resolve(HERE, "..", "..", "..", "..");
export const EVAL_DIR = join(REPO_ROOT, "docs", "thoughts", "plans", "2026-11-24-想法主题归类准确性闭环", "eval");
export const PRIVATE_DIR = join(EVAL_DIR, "private");
export const RESULTS_DIR = join(PRIVATE_DIR, "results");
export const VECTORS_DIR = join(PRIVATE_DIR, "vectors");

/** 带真实正文的文件只能落在被 git 忽略的目录里：写之前确认。 */
export function assertGitIgnored(path) {
  try {
    execFileSync("git", ["check-ignore", "-q", path], { cwd: REPO_ROOT, stdio: "ignore" });
  } catch {
    throw new Error(`该文件含真实想法正文，只能写在被 git 忽略的目录里：${path}`);
  }
}
