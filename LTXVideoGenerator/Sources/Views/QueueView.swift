import SwiftUI

struct QueueView: View {
    @EnvironmentObject var generationService: GenerationService
    @EnvironmentObject var productionQueue: ProductionQueueService
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Label("Queue", systemImage: "list.bullet")
                    .font(.headline)
                
                Spacer()
                
                if !generationService.queue.isEmpty {
                    Button {
                        generationService.clearQueue()
                    } label: {
                        Text("Clear")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            
            Divider()
            
            if generationService.queue.isEmpty && generationService.currentRequest == nil {
                // Empty state
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    
                    Text("No pending generations")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Queue list
                ScrollView {
                    LazyVStack(spacing: 8) {
                        // Current request
                        if let current = generationService.currentRequest {
                            QueueItemView(
                                request: current,
                                isCurrent: true,
                                progress: generationService.progress,
                                statusMessage: generationService.statusMessage,
                                startedAt: generationService.currentRequestStartedAt
                            ) {
                                productionQueue.cancelActiveRenderer()
                            }
                        }
                        
                        // Pending requests
                        ForEach(generationService.queue.filter { $0.status == .pending }) { request in
                            QueueItemView(
                                request: request,
                                isCurrent: false,
                                progress: 0,
                                statusMessage: "",
                                startedAt: nil
                            ) {
                                generationService.removeFromQueue(request)
                            }
                            .contextMenu {
                                Button("Move Up") {
                                    generationService.moveUp(request)
                                }
                                Button("Move Down") {
                                    generationService.moveDown(request)
                                }
                                Divider()
                                Button("Remove", role: .destructive) {
                                    generationService.removeFromQueue(request)
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .background(.background)
    }
}

struct QueueItemView: View {
    let request: GenerationRequest
    let isCurrent: Bool
    let progress: Double
    let statusMessage: String
    let startedAt: Date?
    let onRemove: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                // Status indicator
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(request.prompt)
                        .font(.subheadline)
                        .lineLimit(2)
                    
                    HStack(spacing: 8) {
                        Text("\(request.parameters.width)×\(request.parameters.height)")
                        Text("•")
                        Text("\(request.parameters.numFrames) frames")
                        Text("•")
                        Text("\(request.parameters.numInferenceSteps) steps")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Button {
                    onRemove()
                } label: {
                    Image(systemName: isCurrent ? "xmark.circle.fill" : "trash")
                        .foregroundStyle(isCurrent ? .red : .secondary)
                }
                .buttonStyle(.borderless)
                .help(isCurrent ? "Cancel" : "Remove")
            }
            
            if isCurrent {
                VStack(alignment: .leading, spacing: 4) {
                    if MiniMaxH3ProgressPresentation.isIndeterminate(
                        modelID: request.modelId,
                        isCurrent: isCurrent,
                        progress: progress
                    ) {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .accessibilityLabel("MiniMax H3 generation active")
                    } else {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                    }
                    
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if request.modelId == MiniMaxH3Configuration.modelID,
                       let startedAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(MiniMaxH3ProgressPresentation.elapsedText(
                                since: startedAt,
                                now: context.date
                            ))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isCurrent ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isCurrent ? Color.accentColor.opacity(0.3) : .clear, lineWidth: 1)
        )
    }
    
    private var statusColor: Color {
        switch request.status {
        case .pending:
            return .gray
        case .processing:
            return .blue
        case .completed:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .orange
        }
    }
}

#if !SPM_BUILD
#Preview {
    QueueView()
        .environmentObject(GenerationService(historyManager: HistoryManager()))
        .environmentObject(ProductionQueueService.shared)
        .frame(width: 350, height: 400)
}
#endif
