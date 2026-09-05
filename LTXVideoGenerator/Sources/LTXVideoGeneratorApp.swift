import AppKit
import SwiftUI

final class LocalVideoStudioAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        // Only a process launched and tracked by this app instance is stopped.
        // A compatible mlx-serve found at the endpoint remains externally
        // owned and is never terminated here.
        MiniMaxH3RuntimeManager.shared.stopOwnedServer()
    }
}

// SPM_BUILD: the CLT/SPM harness builds these sources as a library for
// compile-checking and unit tests; the @main entry point only exists in the
// Xcode app build.
#if !SPM_BUILD
@main
#endif
struct LTXVideoGeneratorApp: App {
    @NSApplicationDelegateAdaptor(LocalVideoStudioAppDelegate.self) private var appDelegate
    
    init() {
        // Don't configure Python here - defer until after subprocess validation
        // This prevents crashes from PythonKit trying to load invalid Python
    }
    
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
        
        Settings {
            SettingsRootView()
        }
    }
}

struct RootView: View {
    @Environment(\.openSettings) private var openSettingsAction
    @StateObject private var historyManager: HistoryManager
    @StateObject private var presetManager: PresetManager
    @StateObject private var characterProfileManager: CharacterProfileManager
    @StateObject private var generationService: GenerationService
    @State private var showPythonSetupAlert = false
    @State private var hasCheckedPython = false
    @StateObject private var healthManager = DependencyHealthManager.shared
    @State private var pythonCheckMessage = ""
    @State private var showLaunchPackageUpgradePrompt = false
    @State private var pendingLaunchUpgradeDetails: PythonDetails?
    @State private var launchPythonPathForUpgrade = ""
    @State private var showPythonUpdateCompleteAlert = false
    
    init() {
        let history = HistoryManager()
        _historyManager = StateObject(wrappedValue: history)
        _presetManager = StateObject(wrappedValue: PresetManager())
        _characterProfileManager = StateObject(wrappedValue: CharacterProfileManager())
        _generationService = StateObject(wrappedValue: GenerationService(historyManager: history))
    }
    
    /// Check if Python is configured by verifying the saved path exists
    private var hasPythonPath: Bool {
        guard let path = UserDefaults.standard.string(forKey: "pythonPath"),
              !path.isEmpty else {
            return false
        }
        return FileManager.default.fileExists(atPath: path)
    }
    
    var body: some View {
        ContentView()
            .environmentObject(historyManager)
            .environmentObject(presetManager)
            .environmentObject(characterProfileManager)
            .environmentObject(generationService)
            .environmentObject(ProductionQueueService.shared)
            .onAppear {
                // The queue watches the renderer to know when a job is done,
                // and picks up any waiting work restored from the last session.
                ProductionQueueService.shared.attach(generationService: generationService)
            }
            .task {
                historyManager.loadInitialData()
                presetManager.loadInitialData()
                characterProfileManager.loadInitialData()

                // Director extensions
                if FeatureFlags.isEnabled(.derivedModelsV1) {
                    ModelRegistry.shared.refreshVerification(from: CompatibilityLab.shared)
                }
                if FeatureFlags.isEnabled(.localAPIv1) {
                    LocalAPIServer.shared.start(
                        generationService: generationService,
                        historyManager: historyManager
                    )
                }
                if FeatureFlags.isEnabled(.filmProjectV1) {
                    for project in FilmProjectStore.shared.allProjects {
                        FilmProjectStore.shared.reconcileInFlightTakes(projectID: project.id)
                    }
                }
                
                guard !hasCheckedPython else { return }
                hasCheckedPython = true

                let usesMiniMaxH3 = GenerationModelResolver.backend(
                    for: UserDefaults.standard.string(forKey: LTXModelCatalog.selectedModelIDKey)
                ) == .minimaxH3
                
                await healthManager.refresh()
                if !healthManager.canStartGeneration {
                    healthManager.showSetupWizard = true
                } else if !usesMiniMaxH3,
                          let savedPath = UserDefaults.standard.string(forKey: "pythonPath") {
                    let result = await PythonEnvironment.shared.validateWithSubprocess(path: savedPath, automaticInstallAndUpgrade: false)
                    if result.success, let details = result.details {
                        PythonEnvironment.shared.configureForPythonKit(details: details)
                        PythonEnvironment.shared.applyValidatedDetailsForGeneration(path: savedPath, details: details)
                    }
                }
            }
            .sheet(isPresented: $healthManager.showSetupWizard) {
                SetupWizardView()
            }
    }
    
    private func openSettings() {
        DispatchQueue.main.async {
            openSettingsAction()
        }
    }
}

struct SettingsRootView: View {
    var body: some View {
        PreferencesView()
    }
}
