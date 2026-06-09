//
//  AppStartupSplashView.swift
//  Holo
//
//  App 冷启动后的轻量品牌过渡页
//

import SwiftUI

struct AppStartupSplashContainer<Content: View>: View {
    let content: Content

    @State private var isShowingSplash = true
    @State private var splashDidAppear = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            content

            if isShowingSplash {
                AppStartupSplashView(
                    isPresented: $isShowingSplash,
                    didAppear: $splashDidAppear,
                    reduceMotion: reduceMotion
                )
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
    }
}

private struct AppStartupSplashView: View {
    @Binding var isPresented: Bool
    @Binding var didAppear: Bool

    let reduceMotion: Bool

    var body: some View {
        ZStack {
            Image("StartupSplashArtwork")
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .ignoresSafeArea()
                .opacity(didAppear ? 1 : 0)
                .scaleEffect(didAppear || reduceMotion ? 1 : 1.015)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Holo，持续记录，更了解你")
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.5)) {
                didAppear = true
            }

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_150_000_000)
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) {
                    isPresented = false
                }
            }
        }
    }
}

#Preview {
    AppStartupSplashContainer {
        Color.holoBackground
            .ignoresSafeArea()
    }
}
