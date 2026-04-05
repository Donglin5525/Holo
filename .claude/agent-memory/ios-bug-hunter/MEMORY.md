# iOS Bug Hunter - Agent Memory

## Project Structure
- iOS source: `Holo/Holo APP/Holo/Holo/`
- Home view: `Holo/Holo APP/Holo/Holo/Views/HomeView.swift`
- Feature button: `Holo/Holo APP/Holo/Holo/Components/FeatureButton.swift`
- Icon config model: `Holo/Holo APP/Holo/Holo/Models/HomeIconConfig.swift`
- Icon config repo: `Holo/Holo APP/Holo/Holo/Models/HomeIconConfigRepository.swift`
- Build command: `xcodebuild -project Holo.xcodeproj -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
- Simulators: iPhone 17 Pro, iPhone 17 Pro Max, iPhone Air, iPhone 16e (iOS 26.3.1)

## Patterns Found
- See [drag-swap-patterns.md](./drag-swap-patterns.md) for drag & swap bug patterns
- See [charts-crash-patterns.md](./charts-crash-patterns.md) for Swift Charts degenerate data EXC_BREAKPOINT crash pattern
