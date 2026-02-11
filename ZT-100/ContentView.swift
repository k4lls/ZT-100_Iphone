import SwiftUI
import UIKit
import WebKit
import Network
import NetworkExtension
import CoreLocation
import Combine

/// Simple helper view to display a web page inside SwiftUI with WKWebView.
struct EmbeddedWebView: UIViewRepresentable {
    let url: URL
    let reloadToken: UUID
    let onSuccess: () -> Void
    let onFailure: (String) -> Void
    private let timeoutSeconds: TimeInterval = 3

    func makeCoordinator() -> Coordinator {
        Coordinator(onSuccess: onSuccess, onFailure: onFailure, timeoutSeconds: timeoutSeconds)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.contentInset = .zero
        webView.scrollView.scrollIndicatorInsets = .zero
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.alwaysBounceVertical = true
        context.coordinator.startNavigation(for: webView, url: url)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Only navigate when the target URL changes to avoid reload loops.
        if context.coordinator.lastRequestedURL != url {
            context.coordinator.startNavigation(for: uiView, url: url)
        }
        if context.coordinator.lastReloadToken != reloadToken {
            context.coordinator.lastReloadToken = reloadToken
            uiView.reload()
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let onSuccess: () -> Void
        let onFailure: (String) -> Void
        let timeoutSeconds: TimeInterval
        private var timeoutWorkItem: DispatchWorkItem?
        private var navigationActive = false
        private(set) var lastRequestedURL: URL?
        fileprivate var lastReloadToken: UUID?

        init(onSuccess: @escaping () -> Void, onFailure: @escaping (String) -> Void, timeoutSeconds: TimeInterval) {
            self.onSuccess = onSuccess
            self.onFailure = onFailure
            self.timeoutSeconds = timeoutSeconds
        }

        func startNavigation(for webView: WKWebView, url: URL) {
            navigationActive = true
            lastRequestedURL = url
            scheduleTimeout(for: webView)
            webView.load(URLRequest(url: url))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            complete(success: true, message: nil)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            complete(success: false, message: error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            complete(success: false, message: error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            navigationActive = true
            scheduleTimeout(for: webView)
        }

        private func scheduleTimeout(for webView: WKWebView) {
            timeoutWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self, weak webView] in
                guard let self, self.navigationActive else { return }
                webView?.stopLoading()
                self.complete(success: false, message: "Timed out connecting to device.")
            }
            timeoutWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds, execute: workItem)
        }

        private func complete(success: Bool, message: String?) {
            navigationActive = false
            timeoutWorkItem?.cancel()
            if success {
                onSuccess()
            } else if let message {
                onFailure(message)
            } else {
                onFailure("Failed to load page.")
            }
        }

        // MARK: - WKUIDelegate (JS alerts/confirm/prompt)

        func webView(_ webView: WKWebView,
                     runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping () -> Void) {
            presentAlert(title: nil, message: message, actions: [
                UIAlertAction(title: "OK", style: .default) { _ in completionHandler() }
            ])
        }

        func webView(_ webView: WKWebView,
                     runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (Bool) -> Void) {
            presentAlert(title: nil, message: message, actions: [
                UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) },
                UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) }
            ])
        }

        func webView(_ webView: WKWebView,
                     runJavaScriptTextInputPanelWithPrompt prompt: String,
                     defaultText: String?,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (String?) -> Void) {
            DispatchQueue.main.async {
                let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
                alert.addTextField { textField in
                    textField.text = defaultText
                }
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                    completionHandler(nil)
                })
                alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
                    completionHandler(alert.textFields?.first?.text)
                })
                self.present(alert: alert)
            }
        }

        private func presentAlert(title: String?,
                                  message: String,
                                  actions: [UIAlertAction]) {
            DispatchQueue.main.async {
                let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
                actions.forEach { alert.addAction($0) }
                self.present(alert: alert)
            }
        }

        private func present(alert: UIAlertController) {
            guard let presenter = topMostViewController() else {
                return
            }
            if presenter.presentedViewController != nil {
                presenter.dismiss(animated: false) {
                    presenter.present(alert, animated: true)
                }
            } else {
                presenter.present(alert, animated: true)
            }
        }

        private func topMostViewController() -> UIViewController? {
            let scenes = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .filter { $0.activationState == .foregroundActive }
            let windows = scenes.flatMap { $0.windows }
            guard let root = windows.first(where: { $0.isKeyWindow })?.rootViewController else {
                return windows.first?.rootViewController
            }
            var top = root
            while let presented = top.presentedViewController {
                top = presented
            }
            return top
        }
    }
}

enum ConnectionState: String {
    case idle = "Idle"
    case connecting = "Connecting…"
    case connected = "Connected"
    case failed = "Failed"
}

struct ContentView: View {
    @AppStorage("zt100_target_ip") private var targetIP: String = "10.10.10.10"
    @Environment(\.scenePhase) private var scenePhase
    @State private var currentURL: URL?
    @State private var status: ConnectionState = .idle
    @State private var alertMessage: String?
    @State private var showingConfig: Bool = false
    @State private var homeTitleHeight: CGFloat = 0
    @State private var homeConnectHeight: CGFloat = 0
    @State private var homeBottomHeight: CGFloat = 0
    @State private var reloadToken = UUID()
    @FocusState private var focusedField: Field?
    @StateObject private var wifiMonitor = WifiMonitor()
    @StateObject private var wifiJoiner = WifiJoiner()
    @StateObject private var locationPermission = LocationPermissionManager()
    @State private var didAttemptJoin = false
    @State private var isJoiningWifi = false
    private let targetSSID = "ZT-100"
    private let ssidRefreshInterval: UInt64 = 3_000_000_000

    enum Field {
        case ip
    }

    private struct HomeTitleHeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = nextValue()
        }
    }

    private struct HomeConnectHeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = nextValue()
        }
    }

    private struct HomeBottomHeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = nextValue()
        }
    }

    private var formattedURL: URL? {
        if targetIP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }

        if targetIP.contains("://") {
            return URL(string: targetIP)
        }

        return URL(string: "http://\(targetIP)")
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [Color.blue.opacity(0.2), Color.teal.opacity(0.2), Color.gray.opacity(0.1)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var mainContent: some View {
        if let url = currentURL {
            webPage(url: url)
        } else {
            homePage
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                backgroundGradient
                mainContent
            }
            .sheet(isPresented: $showingConfig) {
                NavigationStack {
                    Form {
                        Section("Device address") {
                            TextField("IP or URL (ex: 192.168.4.1)", text: $targetIP)
                                .keyboardType(.numbersAndPunctuation)
                                .textContentType(.URL)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .focused($focusedField, equals: .ip)
                            Button("Reset to default (10.10.10.10)") {
                                targetIP = "10.10.10.10"
                            }
                        }
                    }
                    .navigationTitle("Configuration")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") {
                                showingConfig = false
                            }
                        }
                    }
                }
            }
            .alert("Connection failed", isPresented: Binding<Bool>(
                get: { alertMessage != nil },
                set: { newValue in
                    if !newValue { alertMessage = nil }
                })
            ) {
                Button("OK", role: .cancel) { alertMessage = nil }
            } message: {
                Text(alertMessage ?? "Unknown error")
            }
        }
        .toolbar(currentURL != nil ? .hidden : .visible, for: .navigationBar)
        .toolbar(.hidden, for: .bottomBar)
        .onAppear {
            locationPermission.requestIfNeeded()
            autoJoinWifiIfNeeded()
            refreshSSID()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                handleForeground()
            }
        }
        .onChange(of: wifiMonitor.isWifi) { _, _ in
            refreshSSID()
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            // Poll while active; iOS doesn't provide SSID change callbacks.
            while !Task.isCancelled {
                refreshSSID()
                try? await Task.sleep(nanoseconds: ssidRefreshInterval)
            }
        }
    }

    private func webPage(url: URL) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                EmbeddedWebView(
                    url: url,
                    reloadToken: reloadToken,
                    onSuccess: {
                        status = .connected
                        alertMessage = nil
                    },
                    onFailure: { message in
                        status = .failed
                        alertMessage = message
                        currentURL = nil
                    }
                )
                // Respect the top safe-area (status bar / notch),
                // but let the page run to the bottom edge.
                .ignoresSafeArea(.container, edges: .bottom)

                VStack(spacing: 0) {
                    Color.white
                        .frame(height: proxy.safeAreaInsets.top)
                        .ignoresSafeArea(.container, edges: .top)
                    Spacer()
                }

                Button {
                    currentURL = nil
                    status = .idle
                    alertMessage = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .background(.thinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, proxy.safeAreaInsets.top + 60)
                .padding(.trailing, 12)

                if status == .connecting {
                    ProgressView()
                        .padding(12)
                        .background(.thinMaterial, in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
        }
        .ignoresSafeArea()
    }

    private var homePage: some View {
        GeometryReader { proxy in
            let padding: CGFloat = 16
            let isLandscape = proxy.size.width > proxy.size.height
            let contentWidth = max(0, proxy.size.width - (padding * 2))
            let connectY = proxy.size.height / 2
            let titleToConnectSpacing: CGFloat = 28
            let connectToBottomSpacing: CGFloat = 28
            let portraitTitleAdjust: CGFloat = isLandscape ? 0 : -103

            let titleY =
            connectY
            - (homeConnectHeight / 2)
            - titleToConnectSpacing
            - (homeTitleHeight / 2)
            + portraitTitleAdjust

            let bottomY =
            connectY
            + (homeConnectHeight / 2)
            + connectToBottomSpacing
            + (homeBottomHeight / 2)

            ZStack(alignment: .bottom) {
                if !isLandscape {
                    Image("ZT100Logo")
                        .resizable()
                        .renderingMode(.original)
                        .scaledToFit()
                        .frame(maxWidth: 260)
                        .accessibilityLabel("ZT-100 logo")
                        .padding(.bottom, proxy.safeAreaInsets.bottom + 8)
                        .allowsHitTesting(false)
                }

                ZStack {
                    VStack(spacing: 8) {
                        Text("ZT-100")
                            .font(.largeTitle.weight(.semibold))
                        Text("Connected device portal")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button {
                            if wifiJoiner.currentSSID != targetSSID {
                                attemptJoinWifi(force: true)
                            }
                        } label: {
                            wifiBadge
                        }
                        .buttonStyle(.plain)
                        if isJoiningWifi {
                            ProgressView()
                                .scaleEffect(0.85)
                        }
                        if let ssid = wifiJoiner.currentSSID, ssid != targetSSID {
                            wifiSSIDLabel
                        }
                        if !wifiMonitor.isWifi && wifiJoiner.currentSSID != nil {
                            wifiRouteLabel
                        }
                    }
                    .frame(width: contentWidth)
                    .background(
                        GeometryReader { inner in
                            Color.clear.preference(key: HomeTitleHeightKey.self, value: inner.size.height)
                        }
                    )
                    .position(x: proxy.size.width / 2, y: titleY)

                    Button {
                        focusedField = nil
                        openPage()
                    } label: {
                        Label("Connect", systemImage: "antenna.radiowaves.left.and.right")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue.gradient)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .frame(width: contentWidth)
                    .disabled(formattedURL == nil)
                    .opacity(formattedURL == nil ? 0.6 : 1)
                    .background(
                        GeometryReader { inner in
                            Color.clear.preference(key: HomeConnectHeightKey.self, value: inner.size.height)
                        }
                    )
                    .position(x: proxy.size.width / 2, y: connectY)

                    VStack(spacing: 28) {
                        HStack(spacing: 12) {
                            Button {
                                focusedField = nil
                                openAdminPage()
                            } label: {
                                Label("Admin", systemImage: "lock.shield")
                                    .font(.subheadline.weight(.medium))
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color.black.opacity(0.06))
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .disabled(formattedURL == nil)
                            .opacity(formattedURL == nil ? 0.6 : 1)

                            Button {
                                showingConfig = true
                            } label: {
                                Label("Configure", systemImage: "slider.horizontal.3")
                                    .font(.subheadline.weight(.medium))
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color.black.opacity(0.06))
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                        }

                    }
                    .frame(width: contentWidth)
                    .background(
                        GeometryReader { inner in
                            Color.clear.preference(key: HomeBottomHeightKey.self, value: inner.size.height)
                        }
                    )
                    .position(x: proxy.size.width / 2, y: bottomY)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .onPreferenceChange(HomeTitleHeightKey.self) { newValue in
                homeTitleHeight = newValue
            }
            .onPreferenceChange(HomeConnectHeightKey.self) { newValue in
                homeConnectHeight = newValue
            }
            .onPreferenceChange(HomeBottomHeightKey.self) { newValue in
                homeBottomHeight = newValue
            }
        }
    }

    private func openPage() {
        guard let url = formattedURL else {
            status = .failed
            alertMessage = "Invalid URL"
            currentURL = nil
            return
        }
        status = .connecting
        alertMessage = nil
        currentURL = url
    }

    private func openAdminPage() {
        guard let base = formattedURL,
              let admin = adminURL(from: base) else {
            status = .failed
            alertMessage = "Invalid admin URL"
            return
        }
        status = .connecting
        alertMessage = nil
        currentURL = admin
    }

    /// Derive the admin URL by keeping scheme/host/port and forcing path to /admin.
    private func adminURL(from base: URL) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = "/admin"
        components.query = nil
        return components.url
    }

    /// Fancy Wi‑Fi badge (Wi‑Fi vs offline) shown on the home screen.
    private var wifiBadge: some View {
        let onTarget = wifiJoiner.currentSSID == targetSSID
        let badgeText: String
        let badgeColors: [Color]

        if onTarget {
            badgeText = "On \(targetSSID)"
            badgeColors = [Color.green.opacity(0.4), Color.green.opacity(0.2)]
        } else if wifiMonitor.isWifi {
            badgeText = "Wi‑Fi ON"
            badgeColors = [Color.blue.opacity(0.35), Color.blue.opacity(0.2)]
        } else {
            badgeText = "Wi‑Fi OFF"
            badgeColors = [Color.red.opacity(0.4), Color.red.opacity(0.2)]
        }

        return HStack(spacing: 8) {
            Image(systemName: (onTarget || wifiMonitor.isWifi) ? "wifi" : "wifi.slash")
                .font(.headline)
            Text(badgeText)
                .font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            LinearGradient(
                colors: badgeColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.4), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.1), radius: 6, x: 0, y: 3)
        .padding(.top, 4)
    }

    private var wifiSSIDLabel: some View {
        let hasSSID = wifiJoiner.currentSSID != nil
        return Text("SSID: \(wifiJoiner.currentSSID ?? "—")")
            .font(.footnote)
            .foregroundStyle(hasSSID ? .secondary : .tertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.black.opacity(hasSSID ? 0.06 : 0.03), in: Capsule())
    }

    private var wifiRouteLabel: some View {
        Text("Route: \(wifiMonitor.isWifi ? "Wi‑Fi" : "Cellular")")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func autoJoinWifiIfNeeded() {
        attemptJoinWifi(force: false)
    }

    private func attemptJoinWifi(force: Bool) {
        if !force {
            guard !didAttemptJoin else { return }
        }
        didAttemptJoin = true
        isJoiningWifi = true
        wifiJoiner.refreshSSID { currentSSID in
            guard currentSSID != targetSSID else {
                isJoiningWifi = false
                return
            }
            if force {
                // Clear any saved config so iOS shows the join prompt again.
                NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: targetSSID)
            }
            wifiJoiner.join(ssid: targetSSID, passphrase: nil) { error in
                isJoiningWifi = false
                if let error = error as NSError?,
                   error.domain == NEHotspotConfigurationErrorDomain,
                   error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
                    refreshSSID()
                    return
                }
                if let error {
                    alertMessage = error.localizedDescription
                } else {
                    refreshSSID()
                }
            }
        }
    }

    private func refreshSSID() {
        wifiJoiner.refreshSSID()
    }

    private func handleForeground() {
        refreshSSID()
        attemptJoinWifi(force: false)
        if currentURL != nil {
            reloadToken = UUID()
        }
    }
}

/// Simple Wi‑Fi state monitor (Wi‑Fi vs not) using NWPathMonitor.
final class WifiMonitor: ObservableObject {
    @Published var isWifi = false
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "zt100.wifi.monitor")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isWifi = path.usesInterfaceType(.wifi)
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}

/// Fetch current SSID and request to join a network.
final class WifiJoiner: ObservableObject {
    @Published private(set) var currentSSID: String?

    func refreshSSID(completion: ((String?) -> Void)? = nil) {
        NEHotspotNetwork.fetchCurrent { network in
            DispatchQueue.main.async {
                let ssid = network?.ssid
                self.currentSSID = ssid
                completion?(ssid)
            }
        }
    }

    func join(ssid: String, passphrase: String?, completion: @escaping (Error?) -> Void) {
        let config: NEHotspotConfiguration
        if let passphrase, !passphrase.isEmpty {
            config = NEHotspotConfiguration(ssid: ssid, passphrase: passphrase, isWEP: false)
        } else {
            config = NEHotspotConfiguration(ssid: ssid)
        }
        config.joinOnce = false
        NEHotspotConfigurationManager.shared.apply(config) { error in
            DispatchQueue.main.async {
                completion(error)
            }
        }
    }
}

/// Prompts for location permission so SSID access is available.
final class LocationPermissionManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
    }

    func requestIfNeeded() {
        let status = manager.authorizationStatus
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }
}
