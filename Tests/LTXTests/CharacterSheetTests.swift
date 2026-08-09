import Foundation
@testable import LTXVideoGeneratorCore

private final class MockVisionEnvironmentClient: CharacterSheetVisionEnvironmentClient {
    var models: [String]
    var shouldFail: Bool
    private(set) var calls = 0

    init(models: [String] = [], shouldFail: Bool = false) {
        self.models = models
        self.shouldFail = shouldFail
    }

    func installedVisionModels() async throws -> [String] {
        calls += 1
        if shouldFail { throw CharacterSheetAnalysisError.localVisionUnavailable }
        return models
    }
}

private final class MockVisionProvider: CharacterSheetVisionProvider {
    let name = "mockVision"
    let modelIdentifier: String? = "vision-test"
    var available = true
    var responses: [String]
    private(set) var completeCalls = 0
    private(set) var terminateCalls = 0

    init(responses: [String]) { self.responses = responses }
    func isAvailable() async -> Bool { available }
    func complete(imageData: Data, system: String, prompt: String) async throws -> String {
        completeCalls += 1
        return responses.isEmpty ? "" : responses.removeFirst()
    }
    func terminate() async { terminateCalls += 1 }
}

func runCharacterSheetTests(_ t: TestKit) {
    let valid = """
    {"nameCandidate":"Adventurer Heroine","appearance":{"faceDescription":"soft oval face","hair":"dark brown high ponytail with straight bangs","eyes":"dark brown","ageImpression":"young adult","build":"slim","complexion":"warm complexion","distinguishingFeatures":"friendly expression","generalNotes":""},"defaultCostumeDescription":"navy-and-white adventurer outfit","accessories":["compass pendant","leather pouch"],"detectedViews":["front","side","back","closeUp","expression","costumeDetail"],"expressions":["smiling","surprised"],"continuitySuggestions":["keep the same ponytail and facial characteristics"],"uncertainties":[]}
    """

    t.suite("Character Sheet structured output") {
        do {
            let candidate = try CharacterSheetAnalyzer.parse(
                response: valid, sourceAssetID: UUID(), provider: "test", model: "vision"
            )
            t.checkEqual(candidate.nameCandidate, "Adventurer Heroine", "valid JSON name parses")
            t.checkEqual(candidate.appearance.hair, "dark brown high ponytail with straight bangs", "hair parses")
            t.checkEqual(candidate.detectedViews.map(\.rawValue),
                         ["front", "side", "back", "closeUp", "expression", "costumeDetail"],
                         "all sheet views parse")
            t.checkEqual(candidate.accessories, "compass pendant, leather pouch", "accessories parse")

            let fenced = "Analysis follows:\n```json\n\(valid)\n```\nReview it."
            t.checkEqual(try CharacterSheetAnalyzer.parse(
                response: fenced, sourceAssetID: UUID(), provider: "test", model: nil
            ).appearance.eyes, "dark brown", "fenced JSON with explanation extracts")

            let trailing = valid.replacingOccurrences(of: "\"uncertainties\":[]}",
                                                      with: "\"uncertainties\":[],}")
            t.checkEqual(try CharacterSheetAnalyzer.parse(
                response: trailing, sourceAssetID: UUID(), provider: "test", model: nil
            ).defaultCostumeDescription, "navy-and-white adventurer outfit",
                         "trailing comma is repaired")

            let minimal = """
            {"appearance":{"hair":"black bob"}}
            """
            let minimalCandidate = try CharacterSheetAnalyzer.parse(
                response: minimal, sourceAssetID: UUID(), provider: "test", model: nil
            )
            t.checkEqual(minimalCandidate.appearance.hair, "black bob", "missing optional fields are safe")
            t.check(minimalCandidate.expressions.isEmpty, "missing optional arrays default empty")

            let unknown = valid.replacingOccurrences(of: "\"costumeDetail\"]", with: "\"futureTurnaround\"]")
            t.checkEqual(try CharacterSheetAnalyzer.parse(
                response: unknown, sourceAssetID: UUID(), provider: "test", model: nil
            ).detectedViews.last?.rawValue, "futureTurnaround", "unknown detected view is retained")
        } catch {
            t.check(false, "valid Character Sheet parser cases threw \(error)")
        }

        t.checkThrows(CharacterSheetAnalysisError.invalidSchema(
            "Character Sheet result was missing its required appearance structure."
        ), "missing required core structure rejected") {
            _ = try CharacterSheetAnalyzer.parse(
                response: "{\"nameCandidate\":\"Only a name\"}",
                sourceAssetID: UUID(), provider: "test", model: nil
            )
        }
        t.checkThrows(CharacterSheetAnalysisError.invalidSchema(
            "Character Sheet result was missing its required appearance structure."
        ), "malformed schema rejected") {
            _ = try CharacterSheetAnalyzer.parse(
                response: "{\"appearance\":42}", sourceAssetID: UUID(), provider: "test", model: nil
            )
        }
        t.checkThrows(CharacterSheetAnalysisError.invalidSchema(
            "Character Sheet result contained invalid JSON."
        ), "malformed JSON fails safely") {
            _ = try CharacterSheetAnalyzer.parse(
                response: "{broken JSON}", sourceAssetID: UUID(), provider: "test", model: nil
            )
        }
    }

    t.suite("Vision capability and independent settings") {
        do {
            let tags = try JSONSerialization.data(withJSONObject: ["models": [
                ["name": "text-only:latest"], ["model": "vision-capable:latest"],
            ]])
            t.checkEqual(try OllamaCharacterSheetVisionEnvironmentClient.modelNames(from: tags),
                         ["text-only:latest", "vision-capable:latest"], "installed model names parse without name heuristics")
            let visionShow = try JSONSerialization.data(withJSONObject: ["capabilities": ["completion", "vision"]])
            let textShow = try JSONSerialization.data(withJSONObject: ["capabilities": ["completion"]])
            t.check(try OllamaCharacterSheetVisionEnvironmentClient.capabilities(from: visionShow).contains("vision"),
                    "reported Vision capability accepted")
            t.check(!((try OllamaCharacterSheetVisionEnvironmentClient.capabilities(from: textShow)).contains("vision")),
                    "text-only capability rejected")
        } catch { t.check(false, "Vision capability parsing threw \(error)") }
        t.check(CharacterSheetVisionEnvironmentService.modelUserDefaultsKey != DirectorEnvironmentService.modelUserDefaultsKey,
                "Vision and Director model settings are separate")
        t.checkEqual(OllamaCharacterSheetVisionEnvironmentClient.endpoint.host, "127.0.0.1",
                     "Vision endpoint is loopback-only")

        let suiteName = "LTXTests-vision-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manualClient = MockVisionEnvironmentClient(models: ["vision"])
        let manualService = CharacterSheetVisionEnvironmentService(userDefaults: defaults, client: manualClient)
        let manualDone = DispatchSemaphore(value: 0)
        Task {
            let snapshot = await manualService.refresh(mode: .manual)
            t.checkEqual(snapshot.effectiveMode, .manual, "Manual mode remains manual")
            t.checkEqual(manualClient.calls, 0, "Manual fallback makes no Ollama request")
            manualDone.signal()
        }
        manualDone.wait()

        defaults.set("missing-vision", forKey: CharacterSheetVisionEnvironmentService.modelUserDefaultsKey)
        let missingClient = MockVisionEnvironmentClient(models: [])
        let missingService = CharacterSheetVisionEnvironmentService(userDefaults: defaults, client: missingClient)
        let missingDone = DispatchSemaphore(value: 0)
        Task {
            let snapshot = await missingService.refresh(mode: .auto)
            t.checkEqual(snapshot.effectiveMode, .manual, "missing configured Vision model falls back to Manual")
            t.checkEqual(snapshot.fallbackReason, "noCompatibleVisionModel", "missing model reason recorded")
            missingDone.signal()
        }
        missingDone.wait()

        let unavailableClient = MockVisionEnvironmentClient(shouldFail: true)
        let unavailableService = CharacterSheetVisionEnvironmentService(userDefaults: defaults, client: unavailableClient)
        let unavailableDone = DispatchSemaphore(value: 0)
        Task {
            let snapshot = await unavailableService.refresh(mode: .auto)
            t.checkEqual(snapshot.effectiveMode, .manual, "Ollama unavailable falls back to Manual")
            t.checkEqual(snapshot.fallbackReason, "localVisionUnavailable", "unavailable reason recorded")
            unavailableDone.signal()
        }
        unavailableDone.wait()
    }

    t.suite("Character Sheet analyzer lifecycle") {
        let repairing = MockVisionProvider(responses: ["{broken JSON}", valid])
        let analyzer = CharacterSheetAnalyzer(provider: repairing)
        let repairedDone = DispatchSemaphore(value: 0)
        Task {
            do {
                let result = try await analyzer.analyze(imageData: Data([1, 2, 3]), sourceAssetID: UUID())
                t.checkEqual(result.nameCandidate, "Adventurer Heroine", "one repair retry recovers")
                t.checkEqual(repairing.completeCalls, 2, "repair is bounded to one retry")
                t.checkEqual(repairing.terminateCalls, 1, "Vision model unloaded after analysis")
            } catch { t.check(false, "repairing analyzer threw \(error)") }
            repairedDone.signal()
        }
        repairedDone.wait()

        let failing = MockVisionProvider(responses: ["{bad}", "{still bad}"])
        let failingAnalyzer = CharacterSheetAnalyzer(provider: failing)
        let failedDone = DispatchSemaphore(value: 0)
        Task {
            do {
                _ = try await failingAnalyzer.analyze(imageData: Data([1]), sourceAssetID: UUID())
                t.check(false, "repair exhaustion should fail")
            } catch {
                t.checkEqual(failing.completeCalls, 2, "repair failure does not loop")
                t.checkEqual(failing.terminateCalls, 1, "model unloaded after repair failure")
            }
            failedDone.signal()
        }
        failedDone.wait()

        let blocked = MockVisionProvider(responses: [valid])
        let blockedAnalyzer = CharacterSheetAnalyzer(provider: blocked, generationIsActive: { true })
        let blockedDone = DispatchSemaphore(value: 0)
        Task {
            do {
                _ = try await blockedAnalyzer.analyze(imageData: Data([1]), sourceAssetID: UUID())
                t.check(false, "active video generation should block Vision")
            } catch {
                t.checkEqual(error as? CharacterSheetAnalysisError, .generationInProgress,
                             "generation-active failure is explicit")
                t.checkEqual(blocked.completeCalls, 0, "Vision model is not invoked during LTX generation")
            }
            blockedDone.signal()
        }
        blockedDone.wait()
    }

    t.suite("Character Sheet managed import") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LTXTests-sheet-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourcePNG = root.appendingPathComponent("Hero Sheet.png")
        let sourceJPG = root.appendingPathComponent("Hero Sheet.jpg")
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z0xkAAAAASUVORK5CYII=")!
        let jpg = Data(base64Encoded: "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////2wBDAf//////////////////////////////////////////////////////////////////////////////////////wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAX/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIQAxAAAAF//8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABBQJ//8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAgBAwEBPwF//8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAgBAgEBPwF//8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQAGPwJ//8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPyF//9k=")!
        try? png.write(to: sourcePNG)
        try? jpg.write(to: sourceJPG)
        let originalPNG = try? Data(contentsOf: sourcePNG)
        let store = FilmProjectStore(projectsDirectory: root.appendingPathComponent("Projects"))
        let projectID = UUID(), characterID = UUID()
        do {
            let pngAsset = try store.importCharacterSheet(from: sourcePNG, projectID: projectID, characterID: characterID)
            let jpgAsset = try store.importCharacterSheet(from: sourceJPG, projectID: projectID, characterID: characterID)
            t.checkEqual(pngAsset.type, .characterSheet, "PNG registers characterSheet asset")
            t.checkEqual(jpgAsset.mimeType, "image/jpeg", "JPG import is supported")
            t.check(pngAsset.projectRelativePath?.hasSuffix(".png") == true, "managed PNG keeps safe extension")
            t.check(pngAsset.projectRelativePath != jpgAsset.projectRelativePath, "same display filename cannot overwrite")
            let managed = pngAsset.projectRelativePath.flatMap {
                store.managedCharacterAssetURL(projectID: projectID, relativePath: $0)
            }
            t.check(managed.map { FileManager.default.fileExists(atPath: $0.path) } == true,
                    "project-owned copy exists")
            t.checkEqual(try? Data(contentsOf: sourcePNG), originalPNG, "external original remains untouched")
            store.removeManagedCharacterAsset(projectID: projectID, asset: pngAsset)
            t.checkEqual(try? Data(contentsOf: sourcePNG), originalPNG, "cancel cleanup never deletes original")
        } catch { t.check(false, "managed PNG/JPG import threw \(error)") }

        let unsupported = root.appendingPathComponent("sheet.pdf")
        try? Data([1]).write(to: unsupported)
        t.checkThrows(FilmProjectStore.StoreError.unsupportedCharacterSheetFormat("pdf"),
                      "PDF is deferred") {
            _ = try store.importCharacterSheet(from: unsupported, projectID: projectID, characterID: characterID)
        }
    }

    t.suite("Candidate review mapping and persistence") {
        let asset = CharacterReferenceAsset(
            type: .characterSheet,
            projectRelativePath: "Assets/Characters/new/character-sheet.png",
            originalFilename: "source.png"
        )
        var appearance = CharacterAppearance()
        appearance.faceDescription = "soft oval face"
        appearance.hair = "brown ponytail"
        appearance.eyes = "dark brown"
        appearance.distinguishingFeatures = "straight bangs"
        let candidate = CharacterSheetAnalysisCandidate(
            sourceAssetID: asset.id,
            nameCandidate: "Adventurer Heroine",
            appearance: appearance,
            defaultCostumeDescription: "navy-and-white outfit",
            accessories: "compass pendant",
            detectedViews: [.front, .side, .back],
            expressions: ["smiling"],
            continuitySuggestions: ["keep the same ponytail"],
            uncertainties: [],
            provider: "mockVision",
            model: "vision-test"
        )
        let newID = UUID()
        let created = candidate.applying(
            to: nil, characterID: newID, asset: asset, selection: .defaults(for: nil)
        )
        t.checkEqual(created.id, newID, "new Character receives stable preallocated UUID")
        t.checkEqual(created.name, "Adventurer Heroine", "candidate name maps after review")
        t.checkEqual(created.accessories, "compass pendant", "candidate accessories map")
        t.check(created.lockedTraits.isEmpty, "Vision does not auto-confirm trait locks")
        t.checkEqual(created.referenceAssets.first?.type, .characterSheet, "source sheet relation is saved")
        t.checkEqual(created.referenceAssets.first?.analysisModel, "vision-test", "analysis provenance persists")

        var currentAppearance = CharacterAppearance()
        currentAppearance.hair = "black bob"
        let stableID = UUID()
        let current = BibleCharacter(id: stableID, name: "Maya", appearance: currentAppearance)
        var selection = CharacterSheetFieldSelection.defaults(for: current)
        selection.name = false
        selection.hair = true
        selection.face = false
        selection.eyes = false
        selection.ageImpression = false
        selection.build = false
        selection.complexion = false
        selection.distinguishingFeatures = false
        selection.costume = false
        selection.accessories = false
        selection.continuityNotes = false
        let merged = candidate.applying(
            to: current, characterID: stableID, asset: asset, selection: selection
        )
        t.checkEqual(merged.id, stableID, "existing Character stable ID is preserved")
        t.checkEqual(merged.name, "Maya", "unselected existing name is preserved")
        t.checkEqual(merged.appearance.hair, "brown ponytail", "selected Hair is applied")
        t.check(merged.personality.isEmpty && merged.speakingStyle.isEmpty,
                "image analysis does not invent personality or speaking style")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LTXTests-sheet-project-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FilmProjectStore(projectsDirectory: root)
        var project = FilmProject(title: "Imported Character")
        project.characterBible.characters = [created]
        project.shots = [Shot(index: 0, summary: "Hero enters", characterIDs: [created.id])]
        CharacterPromptPipeline.recompile(project: &project)
        store.save(project)
        let reloaded = FilmProjectStore(projectsDirectory: root).project(id: project.id)
        t.checkEqual(reloaded?.characterBible.characters.first?.id, newID, "imported Character reloads")
        t.checkEqual(reloaded?.characterBible.characters.first?.referenceAssets.first?.detectedViews,
                     ["front", "side", "back"], "detected views reload")
        t.checkEqual(reloaded?.shots.first?.characterIDs, [newID], "Storyboard stable assignment reloads")
        t.check(reloaded?.shots.first?.compiledPrompt.contains("brown ponytail") == true,
                "saved candidate reaches shared PromptCompiler")
        t.check(reloaded?.shots.first?.compiledPrompt.contains("compass pendant") == true,
                "saved accessories reach shared PromptCompiler")
    }
}
