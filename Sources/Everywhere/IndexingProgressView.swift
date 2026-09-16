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
        if indexService.phase == .waiting { return "Search the saved index while indexing waits. Pause holds indexing; Resume starts it immediately." }
        let stats = indexService.progressStats
        return "\(stats.scannedItems.formatted()) items scanned · \(stats.scannedDirectories.formatted()) folders checked · \(stats.skipped.formatted()) skipped"
    }

    var body: some View {
        HStack(spacing: 6) {
            if indexService.isPaused {
                Image(systemName: "pause.circle")
                    .foregroundStyle(.secondary)
            } else if indexService.phase == .waiting {
                Image(systemName: "clock").foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(title)
            }
            Text(title)
                .foregroundStyle(.secondary)
            if indexService.phase != .waiting {
                Text(indexService.progressStats.scannedItems.formatted())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(indexService.progressStats.scannedItems.formatted()) items scanned")
            }
            Button(indexService.isPaused ? "Resume" : "Pause") {
                indexService.togglePause()
            }
            .disabled(!indexService.canPause)
            .help(indexService.canPause
                  ? "Pause or resume the countdown or current scan while Everywhere stays open."
                  : "Finishing the search index; this step cannot be paused.")
        }
        .font(.footnote)
        .controlSize(.small)
        .fixedSize()
        .help(details)
    }
}
