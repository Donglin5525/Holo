//
//  HoloProfileDataSource.swift
//  Holo
//

import Foundation

struct HoloDefaultProfileDataSource: HoloProfileDataSource {

    func snapshot() async -> HoloProfileToolSnapshot? {
        await MainActor.run {
            guard let profile = HoloProfileService.shared.loadSnapshot(), !profile.isEmpty else {
                return nil
            }
            return HoloProfileToolSnapshot(
                preferredName: profile.preferredName,
                language: profile.language,
                timezone: profile.timezone,
                city: profile.city,
                profession: profile.profession,
                communicationStyle: profile.communicationStyle,
                currentFocus: profile.currentFocus,
                lifeContext: profile.lifeContext,
                healthHabitContext: profile.healthHabitContext,
                sensitiveBoundaries: profile.sensitiveBoundaries
            )
        }
    }
}
