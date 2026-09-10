// Vendor patch: CNumKong is header-only; this empty translation unit gives
// xcodebuild a real object file (CNumKong.o) to link against, working around
// Xcode's SPM integration bug for header-only C targets.
// Upstream fix lands -> delete this file. Pinned: NumKong 7.8.2 (6de303be).
