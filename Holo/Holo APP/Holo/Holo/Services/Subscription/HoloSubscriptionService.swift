//
//  HoloSubscriptionService.swift
//  Holo
//
//  StoreKit 购买、恢复购买与服务端会员状态同步。
//

import Combine
import Foundation
import StoreKit

@MainActor
final class HoloSubscriptionService: ObservableObject {
    static let shared = HoloSubscriptionService(entitlementState: .shared)

    @Published private(set) var products: [Product] = []
    @Published private(set) var isLoadingProducts = false
    @Published private(set) var isPurchasing = false

    private let entitlementState: HoloEntitlementState
    private let baseURL: String
    private let session: URLSession
    private let deviceIdProvider: () -> String
    private var updatesTask: Task<Void, Never>?

    init(
        entitlementState: HoloEntitlementState,
        baseURL: String = HoloBackendEnvironment.baseURL,
        session: URLSession = .shared,
        deviceIdProvider: @escaping () -> String = { HoloBackendDeviceIdentity.shared.deviceId }
    ) {
        self.entitlementState = entitlementState
        self.baseURL = baseURL
        self.session = session
        self.deviceIdProvider = deviceIdProvider
        startListeningForTransactions()
    }

    deinit {
        updatesTask?.cancel()
    }

    func refreshStatus() async {
        guard let url = URL(string: "\(baseURL)/v1/subscription/status") else { return }
        entitlementState.setRefreshing(true)
        defer { entitlementState.setRefreshing(false) }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 30
            request.setValue(deviceIdProvider(), forHTTPHeaderField: "X-Holo-Device-Id")

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                entitlementState.setError("会员服务尚未接通，当前按免费版展示")
                return
            }

            let status = try JSONDecoder().decode(HoloSubscriptionStatusResponse.self, from: data)
            entitlementState.apply(status: status)
            HoloServerFeatureFlags.apply(status.featureFlags)
            HoloWidgetSnapshotService.shared.refreshEntitlementSnapshot(
                isPlusActive: status.isPlusActive,
                source: status.source ?? "backend"
            )
        } catch {
            entitlementState.setError("会员状态刷新失败，当前按最近状态展示")
        }
    }

    func loadProducts() async {
        isLoadingProducts = true
        defer { isLoadingProducts = false }

        do {
            products = try await Product.products(
                for: HoloSubscriptionProduct.allCases.map(\.rawValue)
            )
            .sorted { lhs, rhs in
                lhs.id == HoloSubscriptionProduct.plusYearly.rawValue
                    && rhs.id != HoloSubscriptionProduct.plusYearly.rawValue
            }

            if products.isEmpty {
                entitlementState.setError("未读取到会员商品，请确认 StoreKit 配置")
            }
        } catch {
            entitlementState.setError("会员商品加载失败")
        }
    }

    func purchase(_ product: Product) async {
        isPurchasing = true
        defer { isPurchasing = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let verified = try checkVerifiedTransaction(verification)

                #if DEBUG
                if Self.isXcodeTransaction(verified.transaction) {
                    await setDebugAcceptanceMode(.plus)
                    await verified.transaction.finish()
                    if entitlementState.isPlusActive {
                        await HoloPlusActionCoordinator.shared.resumeAfterSuccessfulPurchase()
                    }
                    return
                }
                #endif

                do {
                    try await sync(verified)
                    await verified.transaction.finish()
                    await refreshStatus()
                    await HoloPlusActionCoordinator.shared.resumeAfterSuccessfulPurchase()
                } catch {
                    // 扣款已发生：交易保持未 finish，等 Transaction.updates 重发补偿；
                    // 文案必须与「未扣款失败」区分，否则用户以为被骗
                    entitlementState.setError("购买已成功，会员状态同步中，可能需要几分钟生效")
                }

            case .userCancelled:
                break

            case .pending:
                entitlementState.setError("购买正在等待确认")

            @unknown default:
                break
            }
        } catch {
            entitlementState.setError("购买未完成，请稍后重试")
        }
    }

    func restorePurchases() async {
        do {
            try await AppStore.sync()
            // AppStore.sync 之后必须把 Apple 侧有效凭证逐笔回传服务器：
            // 服务器权益按 deviceId 归属，重装/换设备后 deviceId 变更时，
            // 仅刷新 status 会返回 free；已 finish 的历史交易也不会再经 Transaction.updates 下发
            await syncCurrentEntitlements()
            await refreshStatus()
        } catch {
            entitlementState.setError("恢复购买失败")
        }
    }

    /// 遍历当前设备上的全部有效权益交易，逐笔同步给服务器并补 finish
    private func syncCurrentEntitlements() async {
        for await result in StoreKit.Transaction.currentEntitlements {
            guard let verified = try? checkVerifiedTransaction(result) else { continue }

            #if DEBUG
            if Self.isXcodeTransaction(verified.transaction) { continue }
            #endif

            do {
                try await sync(verified)
                await verified.transaction.finish()
            } catch {
                // 单笔失败不中断其余交易同步；未 finish 的交易仍可经 updates 补偿
                continue
            }
        }
    }

    #if DEBUG
    func setDebugAcceptanceMode(_ mode: HoloAcceptanceMode) async {
        await updateAcceptance(path: "/v1/subscription/acceptance", body: ["mode": mode.rawValue])
    }

    func resetDebugAcceptanceQuotas() async {
        await updateAcceptance(path: "/v1/subscription/acceptance/reset", body: [:])
    }

    private func updateAcceptance(path: String, body: [String: String]) async {
        guard let token = HoloInternalAccessService.shared.session?.token else {
            entitlementState.setError("请先用内部验收账号登录，再切换真机权益")
            return
        }
        guard let url = URL(string: "\(baseURL)\(path)") else { return }

        entitlementState.setRefreshing(true)
        defer { entitlementState.setRefreshing(false) }
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(deviceIdProvider(), forHTTPHeaderField: "X-Holo-Device-Id")
            request.httpBody = try JSONEncoder().encode(body)

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let message = (try? JSONDecoder().decode(
                    HoloSubscriptionErrorResponse.self,
                    from: data
                ))?.error.message
                entitlementState.setError(message ?? "真机验收状态切换失败")
                return
            }

            let status = try JSONDecoder().decode(HoloSubscriptionStatusResponse.self, from: data)
            entitlementState.apply(status: status)
            HoloWidgetSnapshotService.shared.refreshEntitlementSnapshot(
                isPlusActive: status.isPlusActive,
                source: status.source ?? "acceptance"
            )
        } catch {
            entitlementState.setError("真机验收状态切换失败，请检查网络后重试")
        }
    }

    private static func isXcodeTransaction(_ transaction: StoreKit.Transaction) -> Bool {
        String(describing: transaction.environment).lowercased() == "xcode"
    }
    #endif

    private func startListeningForTransactions() {
        updatesTask = Task { [weak self] in
            for await result in StoreKit.Transaction.updates {
                guard let self else { return }

                do {
                    let verified = try self.checkVerifiedTransaction(result)

                    #if DEBUG
                    if Self.isXcodeTransaction(verified.transaction) {
                        await self.setDebugAcceptanceMode(.plus)
                        await verified.transaction.finish()
                        if self.entitlementState.isPlusActive {
                            await HoloPlusActionCoordinator.shared.resumeAfterSuccessfulPurchase()
                        }
                        continue
                    }
                    #endif

                    try await self.sync(verified)
                    await verified.transaction.finish()
                    await self.refreshStatus()
                } catch {
                    self.entitlementState.setError("会员状态同步失败")
                }
            }
        }
    }

    private func sync(_ verified: VerifiedStoreKitTransaction) async throws {
        guard let url = URL(string: "\(baseURL)/v1/subscription/sync") else {
            throw URLError(.badURL)
        }
        let transaction = verified.transaction

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceIdProvider(), forHTTPHeaderField: "X-Holo-Device-Id")
        request.httpBody = try JSONEncoder().encode(
            HoloSubscriptionSyncRequest(
                productId: transaction.productID,
                originalTransactionId: String(transaction.originalID),
                transactionId: String(transaction.id),
                signedTransactionInfo: verified.signedTransactionInfo,
                environment: String(describing: transaction.environment),
                expiresAt: transaction.expirationDate.map {
                    ISO8601DateFormatter().string(from: $0)
                }
            )
        )

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    private func checkVerifiedTransaction(
        _ result: VerificationResult<StoreKit.Transaction>
    ) throws -> VerifiedStoreKitTransaction {
        switch result {
        case .unverified:
            throw URLError(.userAuthenticationRequired)
        case .verified(let transaction):
            return VerifiedStoreKitTransaction(
                transaction: transaction,
                signedTransactionInfo: result.jwsRepresentation
            )
        }
    }
}

private struct VerifiedStoreKitTransaction {
    let transaction: StoreKit.Transaction
    let signedTransactionInfo: String
}

private struct HoloSubscriptionSyncRequest: Encodable {
    let productId: String
    let originalTransactionId: String
    let transactionId: String
    let signedTransactionInfo: String
    let environment: String
    let expiresAt: String?
}

private struct HoloSubscriptionErrorResponse: Decodable {
    let error: Payload

    struct Payload: Decodable {
        let message: String
    }
}
