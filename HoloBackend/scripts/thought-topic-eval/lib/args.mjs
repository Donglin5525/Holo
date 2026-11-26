// 想法主题归类评测 · 命令行参数
//
// --key value 或 --key=value；没有取值的开关（--dry-run）读成字符串 "true"。

export function parseArgs(argv) {
  const args = {};
  for (let index = 0; index < argv.length; index += 1) {
    if (!argv[index].startsWith("--")) continue;
    const [key, inline] = argv[index].split("=", 2);
    const next = argv[index + 1];
    args[key.slice(2)] = inline ?? (next !== undefined && !next.startsWith("--") ? argv[++index] : "true");
  }
  return args;
}
