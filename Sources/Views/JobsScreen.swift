import SwiftUI

struct JobsScreen: View {
    @Environment(RemoteClient.self) private var client
    @Binding var section: AppTab

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
                        group(L("Done", "Erledigt"), Array(jobs.filter { $0.state == .finished || $0.state == .cancelled }.prefix(20)))
                    }
                }
            }
            .navigationTitle(L("Jobs", "Aufträge"))
            .toolbar { ToolbarItem(placement: .topBarTrailing) { MacMenu(section: $section) } }
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ jobs: [RemoteJob]) -> some View {
        if !jobs.isEmpty {
            SwiftUI.Section(title) {
                ForEach(jobs) { JobRow(job: $0) }
            }
        }
    }
}

struct JobRow: View {
    @Environment(RemoteClient.self) private var client
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
                    if let progress = job.progress {
                        ProgressView(value: progress)
                    }
                    if let text = job.progressText { Text(text).font(.caption).monospacedDigit().foregroundStyle(.secondary) }
                }
                if let line = job.lastLine, job.active {
                    Text(line).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(2)
                }
                if let failure = job.failure {
                    Text(failure).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            JobButtons(job: job)
        }
        .padding(.vertical, 6)
    }
}

/// Anhalten und Fortsetzen, wie auf dem Mac.
struct JobButtons: View {
    @Environment(RemoteClient.self) private var client
    let job: RemoteJob

    var body: some View {
        HStack(spacing: 12) {
            if job.canResume {
                Button(L("Resume", "Fortsetzen")) { client.perform(.resume(jobId: job.id), key: "resume:\(job.id)") }
                    .buttonStyle(.borderedProminent)
                    .disabled(client.busy.contains("resume:\(job.id)"))
            }
            if job.canCancel {
                Button(L("Cancel", "Abbrechen"), role: .destructive) { client.perform(.cancel(jobId: job.id), key: "cancel:\(job.id)") }
                    .disabled(client.busy.contains("cancel:\(job.id)"))
            }
        }
    }
}

/// Ein Auftrag auf der Seite seines Spiels.
struct JobCard: View {
    let job: RemoteJob

    var body: some View {
        JobRow(job: job)
            .padding(24)
            .background(.regularMaterial, in: .rect(cornerRadius: 28))
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
