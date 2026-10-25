import SwiftUI

/// Zur Seite eines Auftrags.
struct JobRoute: Hashable {
    let id: String
}

struct JobsScreen: View {
    @Environment(RemoteClient.self) private var client
    @Binding var section: AppTab
    @State private var clearing: RemoteChoice?

    var body: some View {
        NavigationStack {
            ConnectionGate(section: $section) {
                let jobs = client.status?.jobs ?? []
                if jobs.isEmpty {
                    ContentUnavailableView(L("No jobs yet", "Noch keine Aufträge"), systemImage: "list.bullet.clipboard",
                                           description: Text(L("Installing or downloading a game creates a job on the Mac.", "Wer ein Spiel installiert oder lädt, legt auf dem Mac einen Auftrag an.")))
                } else {
                    List {
                        group(L("Running and waiting", "Läuft und wartet"), jobs.filter(\.active))
                        group(L("Stopped", "Angehalten"), jobs.filter { $0.state == .stopped || $0.state == .interrupted })
                        group(L("Done", "Erledigt"), jobs.filter { $0.state == .finished || $0.state == .cancelled })
                    }
                }
            }
            .navigationTitle(L("Jobs", "Aufträge"))
            .navigationDestination(for: JobRoute.self) { JobDetail(jobId: $0.id) }
            .navigationDestination(for: String.self) { GameDetail(gameId: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        ForEach(client.status?.clearable ?? []) { choice in
                            Button(choice.title) { clearing = choice }
                        }
                    } label: {
                        Label(L("Clear", "Leeren"), systemImage: "trash")
                    }
                    .disabled(client.connectedMac == nil || (client.status?.clearable ?? []).isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) { MacMenu(section: $section) }
            }
            .confirmationDialog(clearing?.title ?? "", isPresented: Binding(get: { clearing != nil }, set: { if !$0 { clearing = nil } }),
                                titleVisibility: .visible) {
                Button(L("Clear", "Leeren"), role: .destructive) {
                    if let id = clearing?.id { client.perform(.clearJobs(kind: id), key: "clear") }
                }
            } message: {
                Text(L("Takes these jobs off the list on the Mac. Downloaded files and everything on the Vision Pro stay. What is running or waiting is never cleared.",
                       "Nimmt diese Aufträge aus der Liste auf dem Mac. Geladene Dateien und alles auf der Vision Pro bleiben. Was läuft oder wartet, wird nie geleert."))
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ jobs: [RemoteJob]) -> some View {
        if !jobs.isEmpty {
            SwiftUI.Section(title) {
                ForEach(jobs) { job in
                    NavigationLink(value: JobRoute(id: job.id)) { JobRow(job: job) }
                }
            }
        }
    }
}

/// Eine Zeile der Liste: nur zum Ansehen – anhalten und fortsetzen geht auf der Seite des Auftrags.
struct JobRow: View {
    let job: RemoteJob

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: JobLook.symbol(job.state)).font(.title2).foregroundStyle(JobLook.color(job.state)).frame(width: 32)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(job.title).font(.headline)
                    Text(JobLook.kind(job.kind)).foregroundStyle(.secondary)
                    Spacer()
                    Text(job.updated.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.tertiary)
                }
                Text(JobLook.line(job)).font(.subheadline).foregroundStyle(.secondary)
                if job.state == .running {
                    if let progress = job.progress { ProgressView(value: progress) }
                    if let text = job.progressText { Text(text).font(.caption).monospacedDigit().foregroundStyle(.secondary) }
                }
                if let line = job.lastLine, job.active {
                    Text(line).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(2)
                }
                if let failure = job.failure {
                    Text(failure).font(.callout).foregroundStyle(.orange).lineLimit(3)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

/// Die Seite eines Auftrags: Stand, Schritte, was schiefging, und der Verlauf – mit Fortsetzen und Abbrechen, das
/// vorher nachfragt.
struct JobDetail: View {
    @Environment(RemoteClient.self) private var client
    let jobId: String

    var body: some View {
        let job = client.status?.jobs.first { $0.id == jobId }
        Form {
            if let job {
                SwiftUI.Section {
                    HStack(alignment: .top, spacing: 20) {
                        if let game = client.game(job.gameId) {
                            CoverView(game: game).frame(width: 220).clipShape(.rect(cornerRadius: 16))
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(job.title) \(JobLook.kind(job.kind))").font(.title.bold())
                            Label(JobLook.line(job), systemImage: JobLook.symbol(job.state)).foregroundStyle(JobLook.color(job.state))
                            if job.state == .running {
                                if let bars = job.bars {
                                    ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in ProgressBar(bar: bar) }
                                } else if let progress = job.progress {
                                    ProgressBar(bar: RemoteProgress(value: progress, text: job.progressText))
                                } else {
                                    // Bauen und Prüfen melden keinen Stand – nur, dass gearbeitet wird.
                                    HStack(spacing: 10) {
                                        ProgressView().controlSize(.small)
                                        Text(L("Working on it – the log below shows each step.", "In Arbeit – der Verlauf unten zeigt jeden Schritt."))
                                            .font(.callout).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 6)
                }
                .listRowBackground(Color.clear)
                if client.game(job.gameId) != nil {
                    SwiftUI.Section {
                        NavigationLink(value: job.gameId) {
                            Label(L("Open the Game's Page", "Seite des Spiels öffnen"), systemImage: "gamecontroller")
                        }
                    }
                }
            }
            PanelSections(panelId: "job:\(jobId)")
        }
        .navigationTitle(job?.title ?? L("Job", "Auftrag"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Ein Balken mit Überschrift und Stand in Worten – wie auf dem Mac.
struct ProgressBar: View {
    let bar: RemoteProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title = bar.title {
                Text(title).font(.callout).lineLimit(1).truncationMode(.middle).monospacedDigit()
            }
            if let value = bar.value {
                ProgressView(value: value).animation(.easeOut(duration: 0.3), value: value)
            }
            if let text = bar.text {
                Text(text).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

enum JobLook {
    static func symbol(_ state: RemoteJob.State) -> String {
        switch state {
        case .running: return "arrow.triangle.2.circlepath"
        case .queued: return "clock"
        case .finished: return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle"
        case .stopped: return "exclamationmark.triangle.fill"
        case .interrupted: return "pause.circle"
        }
    }

    static func color(_ state: RemoteJob.State) -> Color {
        switch state {
        case .running: return .blue
        case .finished: return .green
        case .stopped: return .orange
        case .queued, .cancelled, .interrupted: return .secondary
        }
    }

    static func kind(_ kind: RemoteJob.Kind) -> String {
        switch kind {
        case .install: return ""
        case .download: return L("– download only", "– nur laden")
        case .addons: return L("– DLC sync", "– DLC-Abgleich")
        case .content: return L("– content sync", "– Inhalte abgleichen")
        }
    }

    static func line(_ job: RemoteJob) -> String {
        let state: String
        switch job.state {
        case .running: state = L("Running", "Läuft")
        case .queued: state = L("Waiting", "Wartet")
        case .finished: return L("Finished", "Abgeschlossen")
        case .cancelled: return L("Cancelled", "Abgebrochen")
        case .stopped: state = L("Stopped", "Angehalten")
        case .interrupted: state = L("Interrupted", "Unterbrochen")
        }
        guard let step = job.step else { return state }
        return "\(state) · " + L("Step \(job.stepIndex) of \(job.stepCount): \(step)", "Schritt \(job.stepIndex) von \(job.stepCount): \(step)")
    }
}
