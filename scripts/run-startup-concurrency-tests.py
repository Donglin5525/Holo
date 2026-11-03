#!/usr/bin/env python3
"""用生产启动状态机和真实 Core Data 验证启动并发；只使用临时库。"""

import argparse
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "Holo/Holo APP/Holo"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--stack-source", type=Path)
    parser.add_argument("--expect-background-deadlock", action="store_true")
    args = parser.parse_args()
    source = (args.stack_source or PROJECT / "Holo/Models/CoreDataStack.swift").read_text()
    # 保留真实容器构建、锁、完成回调与 continuation 代码；仅替换模型、路径和加载边界。
    # 子类只覆写默认目录，避免 NSPersistentContainer 初始化触及用户 Application Support。
    domain = source[:source.index("    // MARK: - 存储装载与冲突恢复")]
    domain = domain.replace("NSPersistentContainer(name:", "StartupTestContainer(name:")
    start = source.index("    /// 主上下文（用于 UI 操作）")
    end = source.index("    // MARK: - Context Management", start)
    domain += source[start:end] + "\n}\n"
    support = (PROJECT / "HoloTests/Models/CoreDataStartupConcurrencyStandaloneTests.swift").read_text()

    with tempfile.TemporaryDirectory(prefix="holo-startup-concurrency-") as temporary:
        work = Path(temporary)
        (work / "Stack.swift").write_text(domain)
        (work / "Tests.swift").write_text(support)
        executable = work / "startup-tests"
        subprocess.run([
            "swiftc", "-parse-as-library", "-module-cache-path", str(work / "modules"),
            str(work / "Stack.swift"), str(work / "Tests.swift"), "-o", str(executable)
        ], check=True)
        scenarios = ["background", "main", "delayed", "failure"]
        if args.expect_background_deadlock:
            scenarios = ["background"]
        for scenario in scenarios:
            try:
                result = subprocess.run(
                    [str(executable), scenario, str(work)],
                    capture_output=True, text=True, timeout=8, check=True
                )
            except subprocess.TimeoutExpired as error:
                output = (error.stdout or b"").decode()
                if args.expect_background_deadlock and "QUERY_READINESS" in output:
                    print("PASS 旧代码在后台加载回调与主线程查询重叠时阻塞超过 8 秒")
                    return
                raise
            print(result.stdout.strip())
            if result.stderr:
                print(result.stderr.strip())
            if args.expect_background_deadlock:
                raise AssertionError("旧代码未复现死锁，不能把未覆盖的时序当作验证通过")
        print("PASS 4 个并发场景，128 次等待全部恢复；真实主上下文配置与失败终态均已核对")

        schema_executable = work / "schema-tests"
        subprocess.run([
            "swiftc", "-parse-as-library", "-DDEBUG", "-default-isolation", "MainActor",
            "-module-cache-path", str(work / "modules"),
            str(PROJECT / "Holo/Services/Sync/CloudKitSchemaInitializer.swift"),
            str(PROJECT / "HoloTests/Models/CloudKitSchemaStartupStandaloneTests.swift"),
            "-o", str(schema_executable)
        ], check=True)
        for scenario in ["normal", "explicit", "duplicate", "failure"]:
            result = subprocess.run(
                [str(schema_executable), scenario, str(work)],
                capture_output=True, text=True, timeout=5, check=True
            )
            print(result.stdout.strip())
        print("PASS 4 个 schema 场景（工程默认 MainActor）：日常启动零调用，慢请求不阻塞，失败不自动重试")


if __name__ == "__main__":
    main()
