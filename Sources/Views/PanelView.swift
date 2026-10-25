import SwiftUI

/// Die Abschnitte einer Seite, die der Mac beschreibt – für eine `Form`. Solange sie zu sehen sind, schickt der Mac
/// jede Änderung.
struct PanelSections: View {
    @Environment(RemoteClient.self) private var client
    let panelId: String

    var body: some View {
        Group {
            if let panel = client.panels[panelId] {
                ForEach(panel.sections) { section in
                    if !section.items.isEmpty || section.footer != nil {
                        SwiftUI.Section {
                            ForEach(section.items) { PanelItemView(panelId: panelId, item: $0) }
                        } header: {
                            if let title = section.title { Text(title) }
                        } footer: {
                            if let footer = section.footer { Text(footer) }
                        }
                    }
                }
            } else {
                SwiftUI.Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(L("Asking the Mac …", "Der Mac wird gefragt …")).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear { client.openPanel(panelId) }
        .onDisappear { client.closePanel(panelId) }
    }
}

/// Eine ganze Seite als Formular – Einrichtung und Einstellungen.
struct PanelScreen: View {
    @Binding var section: AppTab
    let panelId: String
    let title: String

    var body: some View {
        NavigationStack {
            ConnectionGate(section: $section) {
                Form { PanelSections(panelId: panelId) }
            }
            .navigationTitle(title)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { MacMenu(section: $section) } }
        }
    }
}

/// Ein Eintrag: Text, Wert, Schalter, Auswahl, Knopf, Link, Prüfpunkt, Fortschritt oder Verlauf.
struct PanelItemView: View {
    @Environment(RemoteClient.self) private var client
    let panelId: String
    let item: RemoteItem
    /// Was gerade gewählt wurde, bis der Mac den neuen Stand schickt – sonst springt der Schalter kurz zurück.
    @State private var pendingOn: Bool?
    @State private var pendingValue: String?
    @State private var confirming = false
    @State private var asking = false
    @State private var answer = ""

    private var busy: Bool { client.busy.contains("\(panelId)/\(item.id)") }

    var body: some View {
        content
            .onChange(of: item.on) { pendingOn = nil }
            .onChange(of: item.value) { pendingValue = nil }
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .text:
            VStack(alignment: .leading, spacing: 4) {
                if !item.title.isEmpty { Text(item.title).font(.headline).foregroundStyle(color) }
                if let detail = item.detail {
                    Text(detail).foregroundStyle(item.title.isEmpty ? color : .secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        case .fact:
            LabeledContent(item.title, value: item.value ?? "")
        case .toggle:
            Toggle(isOn: Binding(get: { pendingOn ?? item.on ?? false }, set: { on in
                pendingOn = on
                client.act(panelId, item.id, value: on ? "1" : "0")
            })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                    if let detail = item.detail { Text(detail).font(.callout).foregroundStyle(.secondary) }
                }
            }
            .disabled(!item.enabled)
        case .choice:
            Picker(selection: Binding(get: { pendingValue ?? item.value ?? "" }, set: { value in
                pendingValue = value
                client.act(panelId, item.id, value: value)
            })) {
                ForEach(groups, id: \.title) { group in
                    if let title = group.title {
                        SwiftUI.Section(title) { ForEach(group.choices) { Text($0.title).tag($0.id) } }
                    } else {
                        ForEach(group.choices) { Text($0.title).tag($0.id) }
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                    if let detail = item.detail { Text(detail).font(.callout).foregroundStyle(.secondary) }
                }
            }
            .pickerStyle(.menu)
            .disabled(!item.enabled)
        case .action:
            VStack(alignment: .leading, spacing: 6) {
                Button(role: item.style == .destructive ? .destructive : nil) {
                    if item.prompt != nil { answer = ""; asking = true }
                    else if item.confirm != nil { confirming = true }
                    else { client.act(panelId, item.id) }
                } label: {
                    HStack {
                        if busy { ProgressView().controlSize(.small) }
                        Text(item.title)
                    }
                }
                .buttonStyle(.bordered)
                .tint(item.style == .prominent ? .accentColor : nil)
                .disabled(!item.enabled || busy)
                if let detail = item.detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .confirmationDialog(item.title, isPresented: $confirming, titleVisibility: .visible) {
                Button(item.title, role: item.style == .destructive ? .destructive : nil) { client.act(panelId, item.id) }
            } message: {
                Text(item.confirm ?? "")
            }
            .alert(item.title, isPresented: $asking) {
                TextField(item.prompt ?? "", text: $answer)
                Button(L("Send", "Senden")) { client.act(panelId, item.id, value: answer) }
                Button(L("Cancel", "Abbrechen"), role: .cancel) {}
            }
        case .link:
            if let text = item.value, let url = URL(string: text) {
                HStack(spacing: 16) {
                    Link(destination: url) { Label(item.title, systemImage: "safari") }
                    Spacer()
                    if item.shareable == true {
                        ShareLink(item: url) { Label(L("Share", "Teilen"), systemImage: "square.and.arrow.up") }
                    }
                }
            }
        case .check:
            HStack(alignment: .top, spacing: 14) {
                CheckIcon(state: item.state)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.headline)
                    if let detail = item.detail { Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
            }
        case .progress:
            HStack(spacing: 12) {
                ProgressView()
                Text(item.title).foregroundStyle(.secondary)
            }
        case .log:
            ScrollView {
                Text(item.detail ?? "")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            .frame(minHeight: 160, maxHeight: 420)
        }
    }

    private var color: Color {
        switch item.style {
        case .warning: return .orange
        case .success: return .green
        case .secondary: return .secondary
        case .destructive: return .red
        case .normal, .prominent: return .primary
        }
    }

    /// Die Wahlen in ihren Abschnitten, in der Reihenfolge, in der der Mac sie nennt.
    private var groups: [(title: String?, choices: [RemoteChoice])] {
        var result: [(title: String?, choices: [RemoteChoice])] = []
        for choice in item.choices ?? [] {
            if let last = result.last, last.title == choice.section {
                result[result.count - 1].choices.append(choice)
            } else {
                result.append((choice.section, [choice]))
            }
        }
        return result
    }
}

struct CheckIcon: View {
    let state: String?

    var body: some View {
        Group {
            switch state {
            case "ok": Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case "warning": Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case "checking": ProgressView().controlSize(.small)
            default: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
            }
        }
        .font(.title2)
        .frame(width: 30)
    }
}
