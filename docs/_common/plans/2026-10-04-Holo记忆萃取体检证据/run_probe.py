"""只编译真实纯逻辑依赖与体检探针；产物放临时目录，不读取个人数据。"""
from pathlib import Path
import subprocess
import sys
import tempfile

repo = Path(sys.argv[1] if len(sys.argv) > 1 else "/Users/tangyuxuan/Desktop/Claude/HOLO")
app = repo / "Holo/Holo APP/Holo/Holo"
evidence = Path(__file__).resolve().parent
dependencies = [
    "Models/AI/HoloMemoryRecord.swift", "Models/AI/HoloMemoryEvidence.swift",
    "Models/AI/HoloPersonalContextModels.swift", "Models/AI/HoloLongTermMemoryModels.swift",
    "Models/AI/HoloShortTermMemoryModels.swift", "Models/AI/HoloDomainMemoryObservation.swift",
    "Services/AI/MemoryCore/HoloMemoryIdentity.swift", "Services/AI/MemoryCore/HoloMemoryDecisionPolicy.swift",
    "Services/AI/MemoryCore/HoloMemoryActivationPolicy.swift", "Services/AI/MemoryCore/HoloMemoryAttentionPolicy.swift",
    "Services/AI/MemoryCore/HoloMemoryScorer.swift", "Services/AI/MemoryCore/HoloMemoryLifecycle.swift",
    "Services/AI/MemoryCore/HoloSemanticTombstoneMatcher.swift", "Services/AI/MemoryRepository/HoloMemoryRepository.swift",
    "Services/AI/MemoryRepository/HoloMemoryForgettingService.swift", "Services/AI/HoloMemoryFeedbackService.swift",
    "Services/AI/MemoryObservation/HoloMemoryDirtyRegistry.swift", "Services/AI/MemoryObservation/HoloDomainSignalBuilder.swift",
    "Services/AI/MemoryObservation/HoloDomainObservationPackageBuilder.swift",
    "Services/AI/MemoryObservation/HoloDomainMemoryOutputValidator.swift",
    "Services/AI/MemorySignals/ConversationMemorySignalBuilder.swift",
    "Services/AI/PersonalContext/HoloContextSourceReader.swift",
    "Services/AI/PersonalContext/HoloPersonalContextValidator.swift",
    "Services/AI/PersonalContext/HoloContextReconciler.swift",
    "Services/AI/PersonalContext/HoloPersonalContextExtractor.swift",
    "Services/AI/PersonalContext/HoloContextAccessPolicy.swift",
    "Models/AI/HoloPersonalContextControls.swift", "Services/AI/HoloMemoryAttributionReconciler.swift",
]
with tempfile.TemporaryDirectory(prefix="holo-memory-audit-") as temp:
    binary = Path(temp) / "MemoryAuditProbe"
    subprocess.run(["swiftc", "-D", "HOLO_MEMORY_STANDALONE", "-module-cache-path", temp,
                    "-o", str(binary), str(evidence / "MemoryAuditProbe.swift"),
                    *(str(app / item) for item in dependencies)], check=True)
    subprocess.run([str(binary)], check=True)
