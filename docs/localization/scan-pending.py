#!/usr/bin/env python3
"""预扫 Swift 文件里的中文文案，分三桶输出：

  AUTO  已是 SwiftUI 字面量写法，构建自动进词表 —— 不动
  TODO  含中文字符串但不在自动位置 —— 人工逐行判断改造
  SKIP  注释/日志 —— 不动

用法: python3 scan-pending.py <目录或文件> [...]
"""
import re
import sys
import pathlib

# 接受 LocalizedStringKey 的 SwiftUI 常见接口（字面量在此位置 = 自动入表）
AUTO_PATTERNS = re.compile(
    r'\b(Text|Button|Label|Toggle|Picker|navigationTitle|TextField|SecureField|'
    r'confirmationDialog|alert|menu|Section|Link|ProgressView|LabeledContent|'
    r'stepper|Stepper|help|badge|navigationSubtitle|sheettitle|ToolbarItem)\s*\(\s*"'
)
# 这类调用第一参数常是 title/label 之外的间隔写法，宽松兜底：任何 f("中文") 前缀名
SKIP_PREFIXES = re.compile(r'^\s*(//|\*|/\*)')
LOG_PATTERNS = re.compile(r'\b(print|NSLog|os_log|logger\.|Logger\(|debugPrint|assertionFailure|preconditionFailure|fatalError)\b')
CN = re.compile(r'[\u4e00-\u9fff]')
STR_LIT = re.compile(r'"[^"\n]*"')


def classify(line: str):
    if SKIP_PREFIXES.search(line) or not CN.search(line):
        return "SKIP"
    if not STR_LIT.search(line):
        return "SKIP"  # 中文在注释尾部等
    if LOG_PATTERNS.search(line):
        return "SKIP"
    if AUTO_PATTERNS.search(line):
        return "AUTO"
    if re.search(r'String\(localized:', line):
        return "AUTO"  # 已完成改造
    # 跨行调用的独立参数行（整行以 "中文" 开头，如 confirmationDialog 的 title）→ LocalizedStringKey 位置，自动入表
    if line.lstrip().startswith('"'):
        return "AUTO"
    return "TODO"


def main(paths):
    todo = auto = 0
    for root in paths:
        p = pathlib.Path(root)
        files = [p] if p.is_file() else sorted(p.rglob("*.swift"))
        for f in files:
            for i, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
                kind = classify(line)
                if kind == "TODO":
                    todo += 1
                    print(f"TODO {f}:{i}: {line.strip()[:160]}")
                elif kind == "AUTO":
                    auto += 1
    print(f"\n=== AUTO(自动入表,不动) {auto} 行 | TODO(人工判断) {todo} 行 ===")


if __name__ == "__main__":
    main(sys.argv[1:])
