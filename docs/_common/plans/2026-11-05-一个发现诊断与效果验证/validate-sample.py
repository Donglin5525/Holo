#!/usr/bin/env python3
"""用当前 Swift 生产代码重放既有真实模型试评；不读写业务库，不调用模型。"""
import json
import subprocess
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
APP = REPO / "Holo/Holo APP/Holo/Holo"
SOURCE = "d18ac2cd4:docs/_common/plans/2026-10-23-holo-ai-discovery-implementation/试评记录/raw-round-22.json"


def declaration(text, marker):
    """提取纯值类型原文，避免把 Core Data / App 装配带入独立探针。"""
    start = text.index(marker)
    opening = text.index("{", start)
    depth = 1
    cursor = opening + 1
    while depth:
        depth += (text[cursor] == "{") - (text[cursor] == "}")
        cursor += 1
    return text[start:cursor]


def main():
    trial = json.loads(subprocess.check_output(["git", "-C", str(REPO), "show", SOURCE]))
    case = next(row for row in trial["results"] if row["caseID"] == "F01")
    generation = case["generation"]
    evidence = case["verifyEval"]["supportBlocks"]
    inputs = {
        "candidates": generation["envelope"],
        "verification": generation["verifyOfGenerated"]["envelope"],
        "evidence": evidence,
    }
    (HERE / "sample-input.json").write_text(json.dumps(inputs, ensure_ascii=False, indent=2) + "\n")
    store = (APP / "Services/AI/Discovery/DiscoveryStore.swift").read_text()
    retriever = (APP / "Services/AI/Discovery/DiscoveryRetriever.swift").read_text()
    declarations = "import Foundation\n" + declaration(store, "struct DiscoveryPublishedPayload:")
    declarations += "\n" + declaration(retriever, "enum DiscoveryCounterCoverageState:")
    with tempfile.TemporaryDirectory(prefix="holo-discovery-sample-") as temporary:
        temporary = Path(temporary)
        types = temporary / "ValueTypes.swift"
        types.write_text(declarations)
        binary = temporary / "validate-sample"
        command = [
            "swiftc", "-module-cache-path", str(temporary / "cache"),
            str(APP / "Models/AI/Discovery/DiscoveryModels.swift"),
            str(APP / "Services/AI/Discovery/DiscoveryQuoteAlignment.swift"),
            str(APP / "Services/AI/Discovery/DiscoveryPublicationPolicy.swift"),
            str(types), str(HERE / "validate-sample.swift"), "-o", str(binary),
        ]
        subprocess.run(command, check=True)
        subprocess.run([str(binary), str(HERE / "sample-input.json"), str(HERE / "validated-sample.json")], check=True)


if __name__ == "__main__":
    main()
