//
//  UserAvatarView.swift
//  Holo
//
//  全局统一的用户头像展示组件。
//

import SwiftUI

struct UserAvatarView: View {

    let size: CGFloat
    var showsSignedInBadge = false

    @ObservedObject private var repository = UserAvatarRepository.shared
    @AppStorage(UserDisplayNameSettings.displayNameKey)
    private var displayName = UserDisplayNameSettings.fallbackDisplayName

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            avatarContent
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.holoBorder.opacity(0.72), lineWidth: 1))

            if showsSignedInBadge {
                Image(systemName: "checkmark")
                    .font(.system(size: max(7, size * 0.16), weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: max(14, size * 0.30), height: max(14, size * 0.30))
                    .background(Color.holoPrimary, in: Circle())
                    .overlay(Circle().stroke(Color.holoCardBackground, lineWidth: 2))
                    .offset(x: 1, y: 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(repository.hasCustomAvatar ? "用户头像" : "默认用户头像")
    }

    @ViewBuilder
    private var avatarContent: some View {
        if let image = repository.image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else if let initial = displayInitial {
            ZStack {
                Circle().fill(Color.holoPrimary.opacity(0.12))
                Text(initial)
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundColor(.holoPrimary)
            }
        } else {
            ZStack {
                Circle().fill(Color.holoPrimary.opacity(0.12))
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundColor(.holoPrimary)
            }
        }
    }

    private var displayInitial: String? {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != UserDisplayNameSettings.fallbackDisplayName,
              let first = trimmed.first else { return nil }
        return String(first).uppercased()
    }
}
