// Focusidea paywall — StoreKit 2 drop-in (iOS 15+). Replace productID and URLs.
import SwiftUI
import StoreKit

enum PaywallConfig {
    static let productID = "com.focusidea.monthly"   // ← App Store Connect の製品IDと完全一致させる
    static let termsURL = URL(string: "https://juke16gt4.github.io/focusidea-site/terms.html")!     // ← 実URLに変更
    static let privacyURL = URL(string: "https://juke16gt4.github.io/focusidea-site/privacy.html")! // ← 実URLに変更
    static let trialDays = 14
}

/// 試用期間: 初回起動日から14日。Keychain保存なので再インストールでも延長されない。
enum TrialManager {
    private static let key = "focusidea.firstLaunch"
    static var startDate: Date {
        if let s = Keychain.read(key), let t = TimeInterval(s) { return Date(timeIntervalSince1970: t) }
        let now = Date()
        Keychain.write(key, String(now.timeIntervalSince1970))
        return now
    }
    static var endDate: Date { Calendar.current.date(byAdding: .day, value: PaywallConfig.trialDays, to: startDate)! }
    static var isActive: Bool { Date() < endDate }
}

enum Keychain {
    static func read(_ k: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: k,
                                kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func write(_ k: String, _ v: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: k]
        SecItemDelete(base as CFDictionary)
        SecItemAdd(base.merging([kSecValueData as String: Data(v.utf8)]) { $1 } as CFDictionary, nil)
    }
}

@MainActor
final class SubscriptionStore: ObservableObject {
    enum LoadState { case loading, ready(Product), failed }
    @Published var loadState: LoadState = .loading
    @Published var isSubscribed = false
    @Published var isWorking = false
    @Published var message: String?          // ユーザーに見せる結果メッセージ
    private var updates: Task<Void, Never>?

    var hasAccess: Bool { isSubscribed || TrialManager.isActive }

    init() {
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let t) = result { await t.finish() }
                await self?.refreshEntitlement()
            }
        }
        Task { await load() }
    }
    deinit { updates?.cancel() }

    func load() async {
        loadState = .loading
        do {
            let products = try await Product.products(for: [PaywallConfig.productID])
            if let p = products.first { loadState = .ready(p) } else { loadState = .failed }
        } catch { loadState = .failed }
        await refreshEntitlement()
    }

    func refreshEntitlement() async {
        var active = false
        for await r in Transaction.currentEntitlements {
            if case .verified(let t) = r, t.productID == PaywallConfig.productID, t.revocationDate == nil { active = true }
        }
        isSubscribed = active
    }

    func purchase() async {
        guard case .ready(let product) = loadState, !isWorking else { return }
        isWorking = true; message = nil
        defer { isWorking = false }
        do {
            switch try await product.purchase() {
            case .success(let v):
                if case .verified(let t) = v { await t.finish(); await refreshEntitlement() }
                else { message = "購入を確認できませんでした。もう一度お試しください。" }
            case .userCancelled: break
            case .pending: message = "購入は承認待ちです(保護者の承認など)。承認後に自動で有効になります。"
            @unknown default: message = "不明な結果です。もう一度お試しください。"
            }
        } catch { message = "購入に失敗しました: \(error.localizedDescription)" }
    }

    func restore() async {
        isWorking = true; message = nil
        defer { isWorking = false }
        do { try await AppStore.sync() } catch { message = "復元に失敗しました: \(error.localizedDescription)"; return }
        await refreshEntitlement()
        if !isSubscribed { message = "復元できる購入が見つかりませんでした。" }
    }
}

/// 遷移先。アプリ側のルーティングに合わせて処理を割り当てる。
enum PaywallDestination { case mainBoard, trialCompanion }

struct PaywallView: View {
    @ObservedObject var store: SubscriptionStore
    var onSelect: (PaywallDestination) -> Void   // 行き先を選んだら呼ばれる(行き止まりにしない)
    @Environment(\.openURL) private var openURL
    @State private var showDestinationDialog = false

    private var price: String {
        if case .ready(let p) = store.loadState { return p.displayPrice }
        return "$6.99"                          // 表示用の予備。ボタンはロード成功まで無効
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text(TrialManager.isActive ? "無料お試し期間中です" : "14日間のお試し期間が終了しました")
                    .font(.title2.bold()).multilineTextAlignment(.center)
                Text("Focusidea 月額プラン(Focusidea Monthly)").font(.headline)
                Text("\(price) / 月").font(.largeTitle.bold())

                VStack(alignment: .leading, spacing: 6) {
                    Text("• 1か月ごとの自動更新サブスクリプションです")
                    Text("• お試し期間はインストール後14日間(\(TrialManager.endDate.formatted(date: .abbreviated, time: .omitted))まで)")
                    Text("• 購入確定時に Apple ID に課金されます")
                    Text("• 期間終了の24時間以上前に解約しない限り自動更新されます")
                    Text("• 解約: 設定 → Apple ID → サブスクリプション")
                }.font(.footnote).frame(maxWidth: .infinity, alignment: .leading)

                content

                if let m = store.message {
                    Text(m).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                }

                Button("購入を復元") { Task { await store.restore() } }.disabled(store.isWorking)
                Button(TrialManager.isActive ? "お試しを続ける" : "無料機能のみ利用") { showDestinationDialog = true }
                    .foregroundStyle(.secondary)

                Text("購入すると、利用規約とプライバシーポリシーに同意したことになります。")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack(spacing: 16) {
                    Button("利用規約") { openURL(PaywallConfig.termsURL) }
                    Button("プライバシーポリシー") { openURL(PaywallConfig.privacyURL) }
                }.font(.caption)
            }.padding()
        }
        .confirmationDialog("移動先を選んでください", isPresented: $showDestinationDialog, titleVisibility: .visible) {
            Button("MainBoard へ") { onSelect(.mainBoard) }
            Button("TrialCompanion 選択へ") { onSelect(.trialCompanion) }
            Button("キャンセル", role: .cancel) {}
        }
        .onChange(of: store.isSubscribed) { if $0 { onSelect(.mainBoard) } }   // 購入成功→MainBoardへ
    }

    @ViewBuilder private var content: some View {
        switch store.loadState {
        case .loading: ProgressView("読み込み中…")
        case .failed:
            VStack(spacing: 8) {
                Text("プラン情報を取得できません。通信状況を確認してください。").font(.footnote)
                Button("再読み込み") { Task { await store.load() } }.buttonStyle(.bordered)
            }
        case .ready:
            Button {
                Task { await store.purchase() }
            } label: {
                HStack { if store.isWorking { ProgressView().tint(.white) }
                         Text(TrialManager.isActive ? "月額プランに加入する" : "継続する").bold() }
                    .frame(maxWidth: .infinity).padding().background(Color.accentColor)
                    .foregroundStyle(.white).clipShape(RoundedRectangle(cornerRadius: 12))
            }.disabled(store.isWorking)
        }
    }
}
