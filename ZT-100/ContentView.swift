import SwiftUI
import WebKit
import Network
import Combine

/// Simple helper view to display a web page inside SwiftUI with WKWebView.
struct EmbeddedWebView: UIViewRepresentable {
    let url: URL
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
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.alwaysBounceVertical = true
        context.coordinator.startNavigation(for: webView, url: url)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Reload when the URL changes.
        if uiView.url != url {
            context.coordinator.startNavigation(for: uiView, url: url)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onSuccess: () -> Void
        let onFailure: (String) -> Void
        let timeoutSeconds: TimeInterval
        private var timeoutWorkItem: DispatchWorkItem?
        private var navigationActive = false

        init(onSuccess: @escaping () -> Void, onFailure: @escaping (String) -> Void, timeoutSeconds: TimeInterval) {
            self.onSuccess = onSuccess
            self.onFailure = onFailure
            self.timeoutSeconds = timeoutSeconds
        }

        func startNavigation(for webView: WKWebView, url: URL) {
            navigationActive = true
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
    @State private var currentURL: URL?
    @State private var status: ConnectionState = .idle
    @State private var alertMessage: String?
    @State private var showingConfig: Bool = false
    @State private var homeTitleHeight: CGFloat = 0
    @State private var homeConnectHeight: CGFloat = 0
    @FocusState private var focusedField: Field?
    @StateObject private var wifiMonitor = WifiMonitor()

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
    }

    private func webPage(url: URL) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                EmbeddedWebView(
                    url: url,
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
            }
        }
        .ignoresSafeArea()
    }

    private var homePage: some View {
        GeometryReader { proxy in
            let padding: CGFloat = 16
            let connectTopSpacing: CGFloat = 28
            let isLandscape = proxy.size.width > proxy.size.height
            let topSpacer = max(
                0,
                (proxy.size.height / 2)
                - (padding + homeTitleHeight + connectTopSpacing + (homeConnectHeight / 2))
            )

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

                VStack(spacing: 0) {
                    Color.clear.frame(height: topSpacer)

                    VStack(spacing: 28) {
                        VStack(spacing: 8) {
                            Text("ZT-100")
                                .font(.largeTitle.weight(.semibold))
                            Text("Connected device portal")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            wifiBadge
                        }
                        .offset(y: isLandscape ? 0 : -103)
                        .background(
                            GeometryReader { inner in
                                Color.clear.preference(key: HomeTitleHeightKey.self, value: inner.size.height)
                            }
                        )

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
                        .disabled(formattedURL == nil)
                        .opacity(formattedURL == nil ? 0.6 : 1)
                        .background(
                            GeometryReader { inner in
                                Color.clear.preference(key: HomeConnectHeightKey.self, value: inner.size.height)
                            }
                        )

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

                        VStack(spacing: 6) {
                            Text("Make sure your phone is on the ZT-100 Wi‑Fi.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                    }
                }
            }
            .padding(.all, padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .onPreferenceChange(HomeTitleHeightKey.self) { newValue in
                homeTitleHeight = newValue
            }
            .onPreferenceChange(HomeConnectHeightKey.self) { newValue in
                homeConnectHeight = newValue
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
        HStack(spacing: 8) {
            Image(systemName: wifiMonitor.isWifi ? "wifi" : "wifi.slash")
                .font(.headline)
            Text(wifiMonitor.isWifi ? "Wi‑Fi ON" : "Wi‑Fi OFF")
                .font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            LinearGradient(
                colors: wifiMonitor.isWifi
                ? [Color.green.opacity(0.4), Color.green.opacity(0.2)]
                : [Color.red.opacity(0.4), Color.red.opacity(0.2)],
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
