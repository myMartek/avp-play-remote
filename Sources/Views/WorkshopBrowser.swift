import SwiftUI
import WebKit

// Der Steam Workshop eines Spiels, in der Fernbedienung zum Stöbern. Angemeldet wird hier nicht – angesehen wird
// ohne Konto, geladen wird auf dem Mac mit Valves Werkzeug und der Anmeldung, die AVP Play dort schon hat. Auf der
// Seite eines Items schickt „In AVP Play laden“ es an den Mac (`workshopAdd` auf der Seite des Spiels); der Mac
// lädt es und legt es danach von selbst zum installierten Spiel auf die Vision Pro. Seiten außerhalb der Steam
// Community öffnen sich im Browser des Systems.

enum WorkshopLink {
    /// Die Kennung eines Items aus der Adresse seiner Seite in der Steam Community, sonst `nil`.
    static func itemId(_ url: URL?) -> String? {
        guard let url, isSteamCommunity(url), url.path.contains("/filedetails"),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let id = parts.queryItems?.first(where: { $0.name == "id" })?.value,
              !id.isEmpty, id.count <= 20, id.allSatisfy(\.isASCIIDigit) else { return nil }
        return id
    }

    static func isSteamCommunity(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "steamcommunity.com" || host.hasSuffix(".steamcommunity.com")
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

/// Der Zustand der eingebetteten Seite.
@MainActor
@Observable
final class WorkshopPage: NSObject, WKNavigationDelegate, WKUIDelegate {
    let start: URL
    let view: WKWebView
    var url: URL?
    var title = ""
    var loading = false
    var canGoBack = false
    var canGoForward = false
    /// Was außerhalb der Steam Community liegt, geht an den Browser des Systems.
    var openOutside: ((URL) -> Void)?
    private var observations: [NSKeyValueObservation] = []

    init(start: URL) {
        self.start = start
        let configuration = WKWebViewConfiguration()
        // Nichts bleibt hängen: keine Anmeldung, keine Cookies über die Sitzung hinaus.
        configuration.websiteDataStore = .nonPersistent()
        view = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        observations = [
            view.observe(\.url, options: [.initial, .new]) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.url = web.url; self?.update() }
            },
            view.observe(\.title, options: [.new]) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.title = web.title ?? "" }
            },
            view.observe(\.isLoading, options: [.new]) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.loading = web.isLoading; self?.update() }
            },
        ]
        view.load(URLRequest(url: start))
    }

    func goHome() { view.load(URLRequest(url: start)) }

    private func update() {
        canGoBack = view.canGoBack
        canGoForward = view.canGoForward
    }

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                             decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        MainActor.assumeIsolated {
            guard let target = action.request.url else { decisionHandler(.cancel); return }
            if target.scheme == "about" || target.scheme == "blob" || target.scheme == "data" || WorkshopLink.isSteamCommunity(target) {
                decisionHandler(.allow)
                return
            }
            // Bilder und Skripte anderer Server lädt die Seite selbst; hier geht es um Seiten, auf die man tippt.
            if action.targetFrame?.isMainFrame ?? true, target.scheme == "https" || target.scheme == "http" {
                openOutside?(target)
            }
            decisionHandler(.cancel)
        }
    }

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                             decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        // Herunterladen gibt es hier nicht; geladen wird auf dem Mac.
        MainActor.assumeIsolated { decisionHandler(response.canShowMIMEType ? .allow : .cancel) }
    }

    /// Ein Link mit `target="_blank"` öffnet sich in derselben Ansicht.
    nonisolated func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                             for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        MainActor.assumeIsolated {
            if let target = action.request.url {
                if WorkshopLink.isSteamCommunity(target) { webView.load(URLRequest(url: target)) } else { openOutside?(target) }
            }
        }
        return nil
    }
}

struct WorkshopWebView: UIViewRepresentable {
    let page: WorkshopPage
    func makeUIView(context: Context) -> WKWebView { page.view }
    func updateUIView(_ view: WKWebView, context: Context) {}
}

/// Das Fenster mit dem Workshop. `panelId` ist die Seite des Spiels, an die ein Item geht.
struct WorkshopBrowser: View {
    @Environment(RemoteClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let panelId: String
    @State private var page: WorkshopPage
    @State private var sending = false
    @State private var answer: String?

    init(panelId: String, start: URL) {
        self.panelId = panelId
        _page = State(initialValue: WorkshopPage(start: start))
    }

    /// Was der Mac auf der Seite des Spiels gerade zum Workshop sagt, und welche Items in der Liste stehen.
    private var macSays: (busy: Bool, text: String?) {
        let items = client.panels[panelId]?.sections.first(where: { $0.id == "workshop" })?.items ?? []
        if let busy = items.first(where: { $0.id == "workshopBusy" }) { return (true, busy.title) }
        return (false, items.first(where: { $0.id == "workshopSaid" })?.detail)
    }

    private var known: Set<String> {
        let items = client.panels[panelId]?.sections.first(where: { $0.id == "workshop" })?.items ?? []
        return Set(items.compactMap { $0.id.hasPrefix("workshopItem:") ? String($0.id.dropFirst(13)) : nil })
    }

    var body: some View {
        let itemId = WorkshopLink.itemId(page.url)
        let says = macSays
        NavigationStack {
            WorkshopWebView(page: page)
                .navigationTitle(page.title.isEmpty ? "Steam Workshop" : page.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarLeading) {
                        Button { page.view.goBack() } label: { Image(systemName: "chevron.left") }
                            .disabled(!page.canGoBack)
                        Button { page.view.goForward() } label: { Image(systemName: "chevron.right") }
                            .disabled(!page.canGoForward)
                        Button { page.goHome() } label: { Image(systemName: "house") }
                        Button { page.view.reload() } label: { Image(systemName: "arrow.clockwise") }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L("Done", "Fertig")) { dismiss() }
                    }
                    ToolbarItem(placement: .bottomOrnament) {
                        HStack(spacing: 16) {
                            if page.loading { ProgressView().controlSize(.small) }
                            if let itemId, known.contains(itemId) {
                                Label(L("In your list", "Steht in deiner Liste"), systemImage: "checkmark.circle")
                                    .foregroundStyle(.secondary)
                            } else if let itemId {
                                Button {
                                    send(itemId)
                                } label: {
                                    HStack {
                                        if sending { ProgressView().controlSize(.small) }
                                        Label(L("Load into AVP Play", "In AVP Play laden"), systemImage: "square.and.arrow.down")
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(sending || says.busy)
                            } else {
                                Text(L("Open an item to load it into AVP Play.", "Öffne ein Item, um es in AVP Play zu laden."))
                                    .foregroundStyle(.secondary)
                            }
                            if let text = answer ?? says.text {
                                HStack(spacing: 8) {
                                    if says.busy { ProgressView().controlSize(.small) }
                                    Text(text).lineLimit(2).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: 520, alignment: .leading)
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                }
        }
        .frame(minWidth: 900, minHeight: 700)
        .onAppear { page.openOutside = { openURL($0) } }
        .onChange(of: says.text) { answer = nil }
    }

    private func send(_ itemId: String) {
        sending = true
        answer = nil
        Task {
            let error = await client.workshopAdd(panelId, itemId: itemId)
            sending = false
            answer = error ?? L("Sent to the Mac – it fetches the item and then copies it to the Vision Pro.",
                                "An den Mac geschickt – er holt das Item und legt es danach auf die Vision Pro.")
        }
    }
}
