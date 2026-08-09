import SwiftUI

public struct SetupWizardView: View {
    @ObservedObject var healthManager = DependencyHealthManager.shared
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
            if healthManager.statuses[.python] == .checking {
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
            
            Text("Set Up LTX Video Generator")
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
            statusIcon(status)
                .frame(width: 24, height: 24)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(requirement.displayName)
                    .font(.body.weight(.medium))
                
                statusDescription(for: requirement, status: status)
            }
            
            Spacer()
            
            actionButton(for: requirement, status: status)
        }
        .padding(16)
    }
    
    @ViewBuilder
    private func statusIcon(_ status: SetupStatus) -> some View {
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
        var logs = ["LTX Video Generator Diagnostics\n---"]
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
