#!/usr/bin/env python3
"""以临时目录和合成数据复现审查边界；不读写用户 App 数据，不联网。"""
from pathlib import Path
import json
import subprocess
import sys
import tempfile

repo = Path(sys.argv[1] if len(sys.argv) > 1 else "/Users/tangyuxuan/Desktop/Claude/HOLO")
app = repo / "Holo/Holo APP/Holo/Holo"
evidence = Path(__file__).resolve().parent
output = Path(tempfile.mkdtemp(prefix="holo-code-review-repro-"))
print("输出目录：", output, flush=True)
base_models = [
    "Models/AI/HoloMemoryRecord.swift", "Models/AI/HoloMemoryEvidence.swift",
    "Models/AI/HoloPersonalContextModels.swift", "Models/AI/HoloLongTermMemoryModels.swift",
    "Models/AI/HoloShortTermMemoryModels.swift", "Services/AI/MemoryCore/HoloMemoryIdentity.swift",
]
fusion_deps = base_models + [
    "Services/AI/MemoryCore/HoloMemoryDecisionPolicy.swift",
    "Services/AI/MemoryCore/HoloMemoryActivationPolicy.swift",
    "Services/AI/MemoryCore/HoloMemoryAttentionPolicy.swift",
    "Services/AI/MemoryCore/HoloMemoryScorer.swift",
    "Services/AI/MemoryFusion/HoloEvidenceLineageResolver.swift",
    "Services/AI/MemoryFusion/HoloCrossDomainCandidateBuilder.swift",
]
semantic_deps = [
    "Services/AI/SemanticV3/LocalSemanticIndex.swift",
    "Services/AI/SemanticV3/FlatSemanticIndex.swift",
    "Services/AI/SemanticV3/ThoughtSemanticStore.swift",
    "Services/AI/SemanticV3/ThoughtSemanticFeatureFlags.swift",
]
config = [
    ("semantic", "SemanticEdgeProbe.swift", semantic_deps, ["-sanitize=address"], [
        ("semantic-open", ["open"]), ("semantic-negative", ["negative"]),
        ("semantic-short-blob", ["short"]),
    ]),
    ("fusion", "FusionDuplicateProbe.swift", fusion_deps, ["-D", "HOLO_MEMORY_STANDALONE"], [
        ("fusion-duplicate", []),
    ]),
    ("scalar", "ScalarEdgeProbe.swift", [], [], [
        ("integer-overflow", ["integer", "40000"]), ("dst-day", ["dst"]),
    ]),
    ("model", "CoreDataModelProbe.swift", [], [], [("model-migration", [])]),
]
results = []
for name, probe, deps, options, cases in config:
    binary = output / name
    arguments = ["swiftc", *options, "-module-cache-path", str(output / "module-cache"),
                 str(evidence / probe), *(str(app / item) for item in deps), "-o", str(binary)]
    with (output / f"{name}-compile.log").open("w") as log:
        compiled = subprocess.run(arguments, stdout=log, stderr=subprocess.STDOUT)
    if compiled.returncode != 0:
        results.append({"case": name + "-compile", "exit": compiled.returncode})
        print(name, "编译失败，详见输出目录", flush=True)
        continue
    for case, args in cases:
        with (output / f"{case}.log").open("w") as log:
            run = subprocess.run([str(binary), *args], stdout=log, stderr=subprocess.STDOUT)
        results.append({"case": case, "exit": run.returncode})
        print(case, "退出码", run.returncode, flush=True)
(output / "results.json").write_text(json.dumps(results, ensure_ascii=False, indent=2))
