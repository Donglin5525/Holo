#!/usr/bin/env python3
"""从生产文件提取纯计算声明，运行睡眠专项用例；不读取或写入个人健康数据。"""

from pathlib import Path
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1] / "Holo/Holo APP/Holo"


def declaration(source: str, signature: str) -> str:
    start = source.index(signature)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        if source[end] == "{":
            depth += 1
        elif source[end] == "}":
            depth -= 1
        end += 1
    return source[start:end]


def main() -> None:
    repository = (ROOT / "Holo/Models/HealthRepository.swift").read_text()
    timeline = (ROOT / "Holo/Views/Health/Components/SleepTimelineCard.swift").read_text()
    suites = ["HealthSleepTimelineBuilderTests", "HealthSleepSessionSplitterTests", "SleepStructureAnalyzerTests"]
    # 保留生产代码原文；只剥离依赖 App 生命周期的外壳，编译 UI 仍由 xcodebuild 覆盖。
    domain = "import Foundation\nimport HealthKit\n"
    domain += declaration(repository, "struct HealthSleepSampleAggregator") + "\n"
    domain += declaration(repository, "struct HealthSleepDetail") + "\n"
    domain += declaration((ROOT / "Holo/Models/HealthMetricType.swift").read_text(), "struct DailyHealthData") + "\n"
    domain += "enum HealthRepository {\n" + declaration(repository, "nonisolated static func makeSleepDetail") + "\n}\n"
    domain += "enum SleepTimelineCard {\n"
    for method in ["static func tickTimes", "static func deepFocusText", "static func structureSummary", "static func displaySegments"]:
        domain += declaration(timeline, method) + "\n"
    domain += "}\n"

    with tempfile.TemporaryDirectory(prefix="holo-sleep-regression-") as temporary:
        output = Path(temporary)
        domain_file = output / "Domain.swift"
        domain_file.write_text(domain)
        sources = [domain_file]
        sources += [ROOT / f"Holo/Models/{name}.swift" for name in ["HealthSleepTimelineBuilder", "HealthSleepSessionSplitter", "SleepStructureAnalyzer"]]
        case_count = 0
        for suite in suites:
            source = (ROOT / f"HoloTests/Models/{suite}.swift").read_text().replace("@testable import Holo", "")
            case_count += len(re.findall(r"\btest[^\s(]+\(\)", declaration(source, "static func main()")))
            target = output / f"{suite}.swift"
            target.write_text(source)
            sources.append(target)
        launcher = output / "main.swift"
        launcher.write_text("\n".join(f"{suite}.main()" for suite in suites))
        sources.append(launcher)
        executable = output / "sleep-tests"
        subprocess.run(["xcrun", "swiftc", "-DHOLO_XCTEST_BRIDGE", "-module-cache-path", str(output / "cache"),
                        *map(str, sources), "-o", str(executable)], check=True)
        subprocess.run([str(executable)], check=True)
        print(f"睡眠专项回归通过：{case_count} 个用例（使用本机 Apple HealthKit SDK）。")


if __name__ == "__main__":
    main()
