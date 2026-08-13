import SwiftUI
import AppKit

/// The global production queue, shown in the sidebar under the existing render
/// queue.
///
/// Deliberately compact: the point is to glance at it and know what is running,
/// what is waiting, and what went wrong — not to manage a build system.
struct ProductionQueuePanel: View {
    @ObservedObject var queue: ProductionQueueService

    var body: some View {
        let visibleJobs = queue.activeDisplayJobs
        VStack(alignment: .leading, spacing: 8) {
            header
            if visibleJobs.isEmpty {
                Text("Add movies or renders here to run them one after another, unattended.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            } else {
                ForEach(visibleJobs) { job in
                    ProductionQueueRow(job: job, queue: queue)
                    if job.id != visibleJobs.last?.id { Divider().padding(.leading, 12) }
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "list.bullet.rectangle")
                .foregroundStyle(.secondary)
            Text("Production Queue").font(.headline)
            if queue.waitingLabel != nil {
                Text(queue.waitingLabel!)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !queue.activeDisplayJobs.isEmpty {
                Button(queue.isPaused ? "Resume" : "Pause") {
                    queue.setPaused(!queue.isPaused)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .help(queue.isPaused
                      ? "Start waiting jobs again"
                      : "Stop starting new jobs. The running job continues.")
            }
        }
        .padding(.horizontal, 12)
    }
}

private struct ProductionQueueRow: View {
    let job: ProductionJob
    @ObservedObject var queue: ProductionQueueService

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(job.kind.displayName)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text(job.state.displayName)
                    .font(.caption2)
                    .foregroundStyle(statusColor)
                Spacer()
                actions
            }
            Text(job.title.isEmpty ? "Untitled" : job.title)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            if let progress = job.progressText, !job.state.isTerminal {
                Text(progress).font(.caption2).foregroundStyle(.secondary)
            }
            if let reason = job.failureReason {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch job.state {
        case .running: return .blue
        case .waiting: return .secondary
        case .completed: return .green
        case .failed: return .orange
        case .cancelled: return .secondary
        case .interrupted: return .yellow
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 2) {
            if job.canReorder {
                Button { queue.moveUp(jobID: job.id) } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless).help("Move up")
                Button { queue.moveDown(jobID: job.id) } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless).help("Move down")
            }
            if job.canRetry || job.canRestart {
                Button { queue.retry(jobID: job.id) } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(job.canRestart ? "Restart this job from the beginning" : "Retry this job")
            }
            if job.state == .completed, let path = job.outputPath, !path.isEmpty {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: {
                    Image(systemName: "play.rectangle")
                }
                .buttonStyle(.borderless).help("Reveal the finished video")
            }
            if job.canCancel {
                Button { queue.cancel(jobID: job.id) } label: {
                    Image(systemName: "stop.circle")
                }
                .buttonStyle(.borderless).help("Cancel this job")
            }
            if job.state.isTerminal {
                // Removing a queue record never deletes the generated video.
                Button { queue.remove(jobID: job.id) } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless).help("Remove from the queue list (keeps the video)")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

extension ProductionQueueService {
    /// "1 running · 2 waiting", or nil when there is nothing to say.
    var waitingLabel: String? {
        let running = jobs.filter { $0.state == .running }.count
        let waiting = jobs.filter { $0.state == .waiting }.count
        guard running + waiting > 0 else { return nil }
        var parts: [String] = []
        if running > 0 { parts.append("\(running) running") }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        return parts.joined(separator: " · ")
    }
}
