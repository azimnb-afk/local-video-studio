import SwiftUI

public struct SetupWizardView: View {
    @ObservedObject var healthManager = DependencyHealthManager.shared
    @ObservedObject var downloadCoordinator = TextEncoderDownloadCoordinator.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettingsAction
    
    public init() {}
    
    public var body: some View {
        VStack(spacing: 0) {
            headerView
            
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    requiredSection
                    optionalSection
                    
                    if healthManager.isChecking {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("Checking environment...")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 16)
                    }
                }
                .padding(32)
                .frame(maxWidth: 800)
            }
            
            footerView
        }
        .frame(minWidth: 700, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            // Re-check every time the wizard is (re)presented, not only on the
            // very first launch check — otherwise a selection made in
            // Preferences while the wizard was dismissed (or a dependency
            // resolved outside the app, e.g. installing ffmpeg) never gets
            // reflected here, and the wizard shows stale status forever.
            if !healthManager.isChecking {
                Task { await healthManager.refresh() }
            }
        }
    }
    
    private var headerView: some View {
        VStack(spacing: 8) {
            Image(systemName: "gearshape.2.fill")
                .font(.system(size: 40))
                .foregroundStyle(.blue)
                .padding(.bottom, 8)
            
            Text("Set Up Local Video Studio")
                .font(.largeTitle.bold())
            
            Text("Let's make sure your Mac is ready to generate local AI video.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 40)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(Divider(), alignment: .bottom)
    }
    
    private var requiredSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Required for Video Generation")
                .font(.headline)
            
            VStack(spacing: 0) {
                statusRow(for: .python)
                Divider().padding(.leading, 40)
                statusRow(for: .ffmpeg)
                Divider().padding(.leading, 40)
                statusRow(for: .videoModel)
                Divider().padding(.leading, 40)
                statusRow(for: .textEncoder)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        }
    }
    
    private var optionalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Optional Features")
                .font(.headline)
            
            VStack(spacing: 0) {
                statusRow(for: .localDirector)
                Divider().padding(.leading, 40)
                statusRow(for: .vision)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        }
    }
    
    @ViewBuilder
    private func statusRow(for requirement: SetupRequirement) -> some View {
        let status = healthManager.statuses[requirement] ?? .checking
        
        HStack(alignment: .top, spacing: 16) {
            statusIcon(for: requirement, status: status)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(requirement.displayName)
                    .font(.body.weight(.medium))

                statusDescription(for: requirement, status: status)

                if requirement == .textEncoder, case .downloading(let progress, _) = downloadCoordinator.state {
                    if let progress {
                        ProgressView(value: progress)
                            .frame(maxWidth: 220)
                            .controlSize(.small)
                    } else {
                        ProgressView()
                            .frame(maxWidth: 220, alignment: .leading)
                            .controlSize(.small)
                    }
                }
            }

            Spacer()

            actionButton(for: requirement, status: status)
        }
        .padding(16)
    }

    @ViewBuilder
    private func statusIcon(for requirement: SetupRequirement, status: SetupStatus) -> some View {
        if requirement == .textEncoder, case .missing = status {
            textEncoderStatusIcon
        } else {
            defaultStatusIcon(status)
        }
    }

    @ViewBuilder
    private var textEncoderStatusIcon: some View {
        switch downloadCoordinator.state {
        case .downloading:
            ProgressView().controlSize(.small)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .idle, .succeeded:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func defaultStatusIcon(_ status: SetupStatus) -> some View {
        switch status {
        case .checking:
            ProgressView().controlSize(.small)
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .missing, .invalid, .unsupported:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func statusDescription(for requirement: SetupRequirement, status: SetupStatus) -> some View {
        if requirement == .textEncoder, case .missing(let msg) = status {
            textEncoderStatusDescription(fallbackMessage: msg)
        } else {
            defaultStatusDescription(status)
        }
    }

    @ViewBuilder
    private func textEncoderStatusDescription(fallbackMessage: String) -> some View {
        switch downloadCoordinator.state {
        case .idle, .succeeded:
            Text("Not installed. \(fallbackMessage)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .downloading(_, let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let error):
            Text("Download failed: \(error)")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func defaultStatusDescription(_ status: SetupStatus) -> some View {
        switch status {
        case .checking:
            Text("Checking...")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .ready:
            Text("Ready to use.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .missing(let msg), .invalid(let msg), .unsupported(let msg):
            Text(msg)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func actionButton(for requirement: SetupRequirement, status: SetupStatus) -> some View {
        if requirement == .textEncoder, case .missing = status {
            textEncoderDownloadAction()
        } else {
            defaultActionButton(for: requirement, status: status)
        }
    }

    @ViewBuilder
    private func defaultActionButton(for requirement: SetupRequirement, status: SetupStatus) -> some View {
        switch status {
        case .ready, .checking:
            EmptyView()
        case .missing, .invalid, .unsupported:
            switch requirement {
            case .python:
                Button("Open Settings") { openSettings() }
                    .controlSize(.small)
            case .ffmpeg:
                Button("Copy Install Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install ffmpeg", forType: .string)
                }
                .controlSize(.small)
            case .videoModel, .textEncoder:
                Button("Open Settings") { openSettings() }
                    .controlSize(.small)
            case .localDirector, .vision:
                Button("Copy Install Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install --cask ollama", forType: .string)
                }
                .controlSize(.small)
            }
        }
    }

    /// The explicit Text Encoder download action: Selected + Missing shows
    /// Download; a repo-less custom selection routes to Preferences instead
    /// (there is nothing to download yet); an in-flight download shows no
    /// button (progress is shown elsewhere in the row); a failure offers
    /// Retry. Selecting a picker option never reaches this on its own —
    /// only tapping Download does.
    @ViewBuilder
    private func textEncoderDownloadAction() -> some View {
        let encoderID = UserDefaults.standard.string(forKey: LTXTextEncoderCatalog.selectedTextEncoderIDKey)
            ?? LTXTextEncoderCatalog.defaultTextEncoderID
        let repo = LTXTextEncoderCatalog.resolvedTextEncoder(id: encoderID).repo

        if repo.isEmpty {
            Button("Open Settings") { openSettings() }
                .controlSize(.small)
        } else {
            switch downloadCoordinator.state {
            case .idle, .succeeded:
                Button("Download") {
                    Task { await downloadCoordinator.startDownload() }
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            case .downloading:
                EmptyView()
            case .failed:
                Button("Retry") {
                    Task { await downloadCoordinator.retry() }
                }
                .controlSize(.small)
            }
        }
    }
    
    private var footerView: some View {
        HStack {
            Button("Copy Diagnostics") {
                copyDiagnostics()
            }
            .buttonStyle(.link)
            
            Spacer()
            
            Button("Recheck") {
                Task { await healthManager.refresh() }
            }
            .keyboardShortcut("r", modifiers: .command)
            
            if healthManager.isGenerationReady {
                Button("Continue to App") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Continue to App") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(Divider(), alignment: .top)
    }
    
    private func openSettings() {
        dismiss()
        DispatchQueue.main.async {
            openSettingsAction()
        }
    }
    
    private func copyDiagnostics() {
        var logs = ["Local Video Studio Diagnostics\n---"]
        for req in SetupRequirement.allCases {
            let statusStr: String
            if let status = healthManager.statuses[req] {
                switch status {
                case .checking: statusStr = "checking"
                case .ready: statusStr = "ready"
                case .missing(let msg): statusStr = "missing - \(msg)"
                case .invalid(let msg): statusStr = "invalid - \(msg)"
                case .unsupported(let msg): statusStr = "unsupported - \(msg)"
                }
            } else {
                statusStr = "unknown"
            }
            logs.append("\(req.displayName): \(statusStr)")
        }
        
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logs.joined(separator: "\n"), forType: .string)
    }
}

#Preview {
    SetupWizardView()
}
