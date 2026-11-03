#!/usr/bin/env python3
"""独立执行想法样式兼容与迁移验证，全程只使用临时数据库。"""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
project = repo / "Holo/Holo APP/Holo"
source = project / "Holo"
stack = (source / "Models/CoreDataStack.swift").read_text()
start = stack.index("    struct SoftDeleteAttributeSet {")
end = stack.index("\n}\n\n// MARK: - Helper Extensions", start)

with tempfile.TemporaryDirectory(prefix="holo-thought-style-") as directory:
    work = Path(directory)
    support = work / "ModelSupport.swift"
    # 复用生产代码的软删除字段与索引，避免测试自己虚构一套模型形状。
    support.write_text("import CoreData\nimport Foundation\nextension CoreDataStack {\n" + stack[start:end] + "\n}\n")
    executable = work / "tests"
    subprocess.run([
        "swiftc", "-parse-as-library", "-module-cache-path", str(work / "modules"),
        str(source / "Models/ThoughtStyle.swift"),
        str(source / "Models/CoreDataStack+ThoughtEntities.swift"),
        str(support),
        str(project / "HoloTests/Models/ThoughtStyleStandaloneTests.swift"),
        "-o", str(executable)
    ], check=True)
    subprocess.run([str(executable)], check=True)
    font_tests = work / "font-tests"
    subprocess.run([
        "swiftc", "-parse-as-library", "-module-cache-path", str(work / "modules"),
        str(project / "HoloTests/Models/ThoughtFontResourceStandaloneTests.swift"),
        "-o", str(font_tests)
    ], check=True)
    subprocess.run([str(font_tests), str(project)], check=True)
