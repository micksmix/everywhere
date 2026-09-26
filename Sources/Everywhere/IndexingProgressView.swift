import SwiftUI
import EverywhereCore

struct IndexingProgressView: View {
    @EnvironmentObject var indexService: IndexService

    private var title: String {
        if indexService.phase == .waiting {
            let seconds = indexService.countdownSeconds
            let time = String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
            return indexService.isPaused ? "Indexing in \(time) · paused" : "Indexing in \(time)"
        }
        if indexService.isPaused { return "Indexing paused" }
        switch indexService.phase {
        case .waiting: return "Waiting to index"
        case .indexing: return "Indexing…"
        case .reconciling: return "Checking files…"
        case .finalizing: return "Preparing search…"
        case .idle: return "Index up to date"
        }
    }

    private var details: String {
        if indexService.phase == .waiting { return "Search the saved index while indexing waits. Resume starts indexing immediately; Pause Indexing in the Search menu holds the countdown." }
        let stats = indexService.progressStats
        return "\(stats.scannedItems.formatted()) items scanned · \(stats.scannedDirectories.formatted()) folders checked · \(stats.skipped.formatted()) skipped"
    }

    private var waiting: Bool { indexService.phase == .waiting }

    var body: some View {
        HStack(spacing: 6) {
            if indexService.isPaused {
                Image(systemName: "pause.circle")
                    .foregroundStyle(.secondary)
            } else if waiting {
                Image(systemName: "clock").foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(title)
            }
            Text(title)
                .foregroundStyle(.secondary)
            if !waiting {
                Text(indexService.progressStats.scannedItems.formatted())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(indexService.progressStats.scannedItems.formatted()) items scanned")
            }
            Button(waiting || indexService.isPaused ? "Resume" : "Pause") {
                if waiting {
                    indexService.startIndexingNow()
                } else {
                    indexService.togglePause()
                }
            }
            .disabled(!indexService.canPause)
            .help(helpText)
        }
        .font(.footnote)
        .controlSize(.small)
        .fixedSize()
        .help(details)
    }

    private var helpText: String {
        if waiting { return "Start indexing now, skipping the rest of the countdown." }
        return indexService.canPause
              ? "Pause or resume the current scan while Everywhere stays open."
              : "Finishing the search index; this step cannot be paused."
    }
}
