//
//  ReceiptBookingSettingsView.swift
//  Holo
//
//  图片快捷指令自动记账 · 设置与结果中心。
//

import SwiftUI
import UIKit
import UserNotifications

struct ReceiptBookingSettingsView: View {
    @ObservedObject private var consent = HoloAIDataProcessingConsent.shared
    @Environment(\.openURL) private var openURL

    @State private var results: [ReceiptBookingResultStore.StoredResult] = []
    @State private var draftCount = 0
    @State private var showReviewList = false
    @State private var showAIConsent = false
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @AppStorage("receiptShortcutNotificationsEnabled") private var notificationsEnabled = true

    var body: some View {
        List {
            Section {
                hero
                    .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
            }

            if !consent.isGranted {
                Section {
                    Button {
                        showAIConsent = true
                    } label: {
                        Label("开启 AI 图片识别", systemImage: "sparkles")
                    }
                } footer: {
                    Text("图片识别需要 AI 数据处理授权；授权前快捷指令不会上传图片，也不会记账。")
                }
            }

            if draftCount > 0 {
                Section {
                    Button {
                        showReviewList = true
                    } label: {
                        HStack(spacing: 12) {
                            Label("待复核", systemImage: "exclamationmark.circle.fill")
                                .foregroundStyle(Color.orange)
                            Spacer()
                            Text("\(draftCount)")
                                .font(.caption.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.orange.opacity(0.16)))
                                .foregroundStyle(Color.orange)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                } header: {
                    Text("需要你处理")
                } footer: {
                    Text("没有确认的账不会自动入账，草稿与证据图会在 7 天后清理。")
                }
            }

            Section("1 分钟完成设置") {
                setupStep(number: 1, title: "打开快捷指令", detail: "新建快捷指令，先加入“截屏”或“拍照”。")
                setupStep(number: 2, title: "加入 Holo 动作", detail: "搜索并加入“识别图片并记账”，图片选择上一步结果；账户、项目和处理方式均可按需固定。")
                setupStep(number: 3, title: "绑定系统入口", detail: "在系统设置中把这条指令绑定到操作按钮或轻点背面。")

                Button {
                    guard let url = URL(string: "shortcuts://") else { return }
                    openURL(url)
                } label: {
                    Label("打开快捷指令 App", systemImage: "arrow.up.forward.app")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.holoPrimary)
                .padding(.vertical, 4)
            }

            Section {
                Toggle("完成后通知我", isOn: notificationBinding)
                    .tint(.holoPrimary)

                if notificationStatus == .denied {
                    Button("前往系统设置开启通知") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        openURL(url)
                    }
                    .font(.footnote)
                }
            } header: {
                Text("运行反馈")
            } footer: {
                Text("通知只用于提示已入账或需要复核。关闭后仍会正常识别和记账，快捷指令也会显示结果。")
            }

            Section {
                Label("仅在需要复核时暂存压缩图；确认、删除或 7 天到期后自动清理", systemImage: "lock.shield")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Label("自动入账、无关图片和识别失败均不保存原图与 OCR 全文", systemImage: "photo.badge.checkmark")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("隐私")
            }

            if !results.isEmpty {
                Section {
                    ForEach(results) { result in
                        ReceiptBookingResultRow(result: result) {
                            refresh()
                        }
                    }
                } header: {
                    Text("最近结果")
                } footer: {
                    Text("成功记录可在 10 分钟内撤销。")
                }
            }
        }
        .navigationTitle(Text("图片自动记账"))
        .contentMargins(.bottom, 92, for: .scrollContent)
        .task {
            refresh()
            await refreshNotificationStatus()
        }
        .sheet(isPresented: $showReviewList, onDismiss: refresh) {
            ReceiptReviewListView()
        }
        .sheet(isPresented: $showAIConsent) {
            NavigationStack {
                AIDataProcessingConsentView()
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "viewfinder.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.holoPrimary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("按一下，账就记好了")
                        .font(.headline)
                    Text("支付完成后触发操作按钮：Holo 自动识别金额、商户、账户和项目；有疑问的账留给你确认。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 6) {
                statusPill(title: consent.isGranted ? "识别已就绪" : "待开启识别", ready: consent.isGranted)
                statusPill(title: "安全时自动入账", ready: true)
            }
        }
    }

    private func statusPill(title: String, ready: Bool) -> some View {
        Label(title, systemImage: ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .font(.caption.weight(.medium))
            .foregroundStyle(ready ? Color.green : Color.orange)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill((ready ? Color.green : Color.orange).opacity(0.1)))
    }

    private func setupStep(number: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(Color.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.holoPrimary))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
    }

    private var notificationBinding: Binding<Bool> {
        Binding(
            get: {
                notificationsEnabled && [.authorized, .provisional, .ephemeral].contains(notificationStatus)
            },
            set: { enabled in
                if enabled {
                    Task {
                        let granted = await ReceiptBookingNotificationService.shared.requestAuthorizationIfNeeded()
                        notificationsEnabled = granted
                        await refreshNotificationStatus()
                    }
                } else {
                    notificationsEnabled = false
                }
            }
        )
    }

    private func refresh() {
        results = ReceiptBookingResultStore.shared.loadResults()
        draftCount = ReceiptBookingResultStore.shared.loadDrafts().count
    }

    @MainActor
    private func refreshNotificationStatus() async {
        notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}
