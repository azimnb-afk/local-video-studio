import Foundation
import SwiftUI

@MainActor
class PresetManager: ObservableObject {
    @Published var presets: [Preset] = []
    @Published var selectedPreset: Preset?
    
    private let presetsFile: URL
    
    nonisolated init() {
        let appDir = AppStorageDirectory.root
        presetsFile = appDir.appendingPathComponent("presets.json")
    }
    
    func loadInitialData() {
        loadPresets()
        
        // Select default preset
        if selectedPreset == nil {
            selectedPreset = presets.first
        }
    }
    
    // MARK: - Persistence
    
    private func loadPresets() {
        // Start with built-in presets
        presets = Preset.builtInPresets
        
        // Load custom presets
        guard FileManager.default.fileExists(atPath: presetsFile.path) else { return }
        
        do {
            let data = try Data(contentsOf: presetsFile)
            let customPresets = try JSONDecoder().decode([Preset].self, from: data)
            presets.append(contentsOf: customPresets)
        } catch {
            print("Failed to load presets: \(error)")
        }
    }
    
    private func savePresets() {
        // Only save custom presets
        let customPresets = presets.filter { !$0.isBuiltIn }
        
        do {
            let data = try JSONEncoder().encode(customPresets)
            try data.write(to: presetsFile)
        } catch {
            print("Failed to save presets: \(error)")
        }
    }
    
    // MARK: - Management
    
    func addPreset(_ preset: Preset) {
        presets.append(preset)
        savePresets()
    }
    
    func updatePreset(_ preset: Preset) {
        guard !preset.isBuiltIn else { return }
        
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index] = preset
            savePresets()
        }
    }
    
    func deletePreset(_ preset: Preset) {
        guard !preset.isBuiltIn else { return }
        
        presets.removeAll { $0.id == preset.id }
        
        if selectedPreset?.id == preset.id {
            selectedPreset = presets.first
        }
        
        savePresets()
    }
    
    func saveCurrentAsPreset(name: String, parameters: GenerationParameters) -> Preset {
        let preset = Preset(
            name: name,
            parameters: parameters,
            isBuiltIn: false
        )
        addPreset(preset)
        return preset
    }
    
    func duplicatePreset(_ preset: Preset) -> Preset {
        let newPreset = Preset(
            name: "\(preset.name) Copy",
            parameters: preset.parameters,
            isBuiltIn: false
        )
        addPreset(newPreset)
        return newPreset
    }
}
