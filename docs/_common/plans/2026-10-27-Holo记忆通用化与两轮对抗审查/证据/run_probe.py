# 仅用真实模型与合成夹具诊断兼容缺口，不读取 App/CloudKit 数据。
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[5]
app = repo / "Holo/Holo APP/Holo/Holo"
out = Path(tempfile.mkdtemp(prefix="holo-memory-compatibility-", dir="/private/tmp"))
sources = ['Models/AI/HoloMemoryRecord.swift', 'Models/AI/HoloMemoryEvidence.swift', 'Models/AI/HoloPersonalContextModels.swift', 'Models/AI/HoloLongTermMemoryModels.swift', 'Models/AI/HoloShortTermMemoryModels.swift', 'Services/AI/MemoryCore/HoloMemoryIdentity.swift', 'Services/AI/MemoryCore/HoloMemoryActivationPolicy.swift', 'Services/AI/MemoryCore/HoloMemoryAttentionPolicy.swift', 'Services/AI/MemoryCore/HoloMemoryScorer.swift', 'Services/AI/MemoryCore/HoloSemanticTombstoneMatcher.swift', 'Services/AI/MemoryCore/HoloMemoryDecisionPolicy.swift', 'Services/AI/MemoryRepository/HoloMemoryRepository.swift', 'Services/AI/HoloMemoryFeedbackService.swift', 'Services/AI/MemoryRepository/HoloMemoryForgettingService.swift', 'Services/AI/MemoryDiagnostics/HoloMemoryDecisionBaselineSnapshot.swift', 'Services/AI/MemoryCore/HoloMemoryManagementProjection.swift', 'Services/AI/MemoryCore/HoloMemoryAnswerEligibility.swift']
command = ["swiftc", "-D", "HOLO_MEMORY_STANDALONE", "-module-cache-path", str(out / "ModuleCache")]
command += [str(app / name) for name in sources]
command += [str(app.parent / "HoloTests/Services/AI/HoloMemoryFiveWayFixtures.swift"), str(Path(__file__).with_name("CompatibilityProbe.swift")), "-o", str(out / "probe")]
subprocess.run(command, check=True)
subprocess.run([str(out / "probe")], check=True)
