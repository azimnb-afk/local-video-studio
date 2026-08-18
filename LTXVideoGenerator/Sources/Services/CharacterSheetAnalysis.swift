import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Shared structured JSON utilities

/// Conservative transport helpers shared by Storyboard and Character Sheet
/// structured-output pipelines. They extract one balanced object and repair
/// only trailing commas outside strings; they never invent domain content.
enum StructuredJSONUtilities {
    static func objectCandidates(from response: String) -> [String] {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var candidates = [trimmed]
        if let object = firstJSONObject(in: trimmed), object != trimmed {
            candidates.append(object)
        }
        return candidates
    }

    static func firstJSONObject(in text: String) -> String? {
        var start: String.Index?
        var depth = 0
        var inString = false
        var escaped = false
        for index in text.indices {
            let character = text[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            if character == "\"" { inString = true; continue }
            if character == "{" {
                if depth == 0 { start = index }
                depth += 1
            } else if character == "}", depth > 0 {
                depth -= 1
                if depth == 0, let start { return String(text[start...index]) }
            }
        }
        return nil
    }

    static func removingTrailingCommas(from text: String) -> String {
        let characters = Array(text)
        var output = ""
        var inString = false
        var escaped = false
        for index in characters.indices {
            let character = characters[index]
            if inString {
                output.append(character)
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            if character == "\"" { inString = true; output.append(character); continue }
            if character == "," {
                var next = index + 1
                while next < characters.count, characters[next].isWhitespace { next += 1 }
                if next < characters.count, characters[next] == "}" || characters[next] == "]" { continue }
            }
            output.append(character)
        }
        return output
    }
}

// MARK: - Candidate model

/// String-backed so an older app can retain a future view label without
/// rejecting the entire analysis result.
struct DetectedCharacterView: RawRepresentable, Codable, Hashable, Identifiable {
    var rawValue: String
    var id: String { rawValue }

    static let front = Self(rawValue: "front")
    static let side = Self(rawValue: "side")
    static let back = Self(rawValue: "back")
    static let closeUp = Self(rawValue: "closeUp")
    static let expression = Self(rawValue: "expression")
    static let costumeDetail = Self(rawValue: "costumeDetail")
    static let unknown = Self(rawValue: "unknown")
}

struct CharacterSheetAnalysisCandidate: Equatable, Identifiable {
    var id: UUID = UUID()
    var sourceAssetID: UUID
    var nameCandidate: String = ""
    var appearance: CharacterAppearance = CharacterAppearance()
    var defaultCostumeDescription: String = ""
    var accessories: String = ""
    var detectedViews: [DetectedCharacterView] = []
    var expressions: [String] = []
    var continuitySuggestions: [String] = []
    var uncertainties: [String] = []
    var provider: String
    var model: String?
    var createdAt: Date = Date()
}

struct CharacterSheetFieldSelection: Equatable {
    var name = true
    var face = true
    var hair = true
    var eyes = true
    var ageImpression = true
    var build = true
    var complexion = true
    var distinguishingFeatures = true
    var costume = true
    var accessories = true
    var continuityNotes = true

    static func defaults(for current: BibleCharacter?) -> Self {
        guard let current else { return Self() }
        return Self(
            name: current.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            face: current.appearance.faceDescription.isEmpty,
            hair: current.appearance.hair.isEmpty,
            eyes: current.appearance.eyes.isEmpty,
            ageImpression: current.appearance.ageImpression.isEmpty,
            build: current.appearance.build.isEmpty,
            complexion: current.appearance.complexion.isEmpty,
            distinguishingFeatures: current.appearance.distinguishingFeatures.isEmpty,
            costume: current.defaultCostume.isEmpty,
            accessories: current.accessories.isEmpty,
            continuityNotes: current.continuityNotes.isEmpty
        )
    }
}

extension CharacterSheetAnalysisCandidate {
    /// User review is the truth boundary. Vision output is applied only for
    /// fields explicitly selected in the review UI; trait locks, personality,
    /// speaking style, aliases, and role notes are never inferred here.
    func applying(
        to current: BibleCharacter?,
        characterID: UUID,
        asset inputAsset: CharacterReferenceAsset,
        selection: CharacterSheetFieldSelection
    ) -> BibleCharacter {
        var result = current ?? BibleCharacter(id: characterID, name: "")
        if selection.name { result.name = nameCandidate.trimmed }
        if selection.face { result.appearance.faceDescription = appearance.faceDescription.trimmed }
        if selection.hair { result.appearance.hair = appearance.hair.trimmed }
        if selection.eyes { result.appearance.eyes = appearance.eyes.trimmed }
        if selection.ageImpression { result.appearance.ageImpression = appearance.ageImpression.trimmed }
        if selection.build { result.appearance.build = appearance.build.trimmed }
        if selection.complexion { result.appearance.complexion = appearance.complexion.trimmed }
        if selection.distinguishingFeatures {
            result.appearance.distinguishingFeatures = appearance.distinguishingFeatures.trimmed
        }
        if selection.costume { result.defaultCostume = defaultCostumeDescription.trimmed }
        if selection.accessories { result.accessories = accessories.trimmed }
        if selection.continuityNotes {
            result.continuityNotes = continuitySuggestions.joined(separator: " ").trimmed
        }

        var asset = inputAsset
        asset.detectedViews = detectedViews.map(\.rawValue)
        asset.expressions = expressions
        asset.analysisProvider = provider == "manual" ? nil : provider
        asset.analysisModel = model
        asset.analyzedAt = provider == "manual" ? nil : createdAt
        let uncertaintyNote = uncertainties.isEmpty
            ? ""
            : "Analysis uncertainties: " + uncertainties.joined(separator: "; ")
        asset.notes = [asset.notes, uncertaintyNote]
            .map { $0.trimmed }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        if !result.referenceAssets.contains(where: { $0.id == asset.id }) {
            result.referenceAssets.append(asset)
        }
        result.updatedAt = Date()
        return result
    }
}

// MARK: - Vision environment

enum CharacterSheetAnalysisMode: String, CaseIterable, Identifiable {
    case auto
    case localVision
    case manual

    static let userDefaultsKey = "characterSheetAnalysisMode"
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .localVision: return "Local Vision"
        case .manual: return "Manual"
        }
    }

    static func selected(userDefaults: UserDefaults = .standard) -> Self {
        Self(rawValue: userDefaults.string(forKey: userDefaultsKey) ?? "") ?? .auto
    }
}

struct CharacterSheetVisionSnapshot: Equatable {
    var requestedMode: CharacterSheetAnalysisMode
    var effectiveMode: CharacterSheetAnalysisMode
    var installedVisionModels: [String]
    var configuredModel: String?
    var effectiveModel: String?
    var fallbackReason: String?
}

protocol CharacterSheetVisionEnvironmentClient {
    func installedVisionModels() async throws -> [String]
}

/// Capability is obtained from Ollama `/api/show`; model names are never used
/// as a proxy for image support. Every request is loopback-only.
final class OllamaCharacterSheetVisionEnvironmentClient: CharacterSheetVisionEnvironmentClient {
    struct ModelEntry: Equatable {
        var name: String
        var capabilities: Set<String>?
    }
    static let endpoint = URL(string: "http://127.0.0.1:11434")!
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func installedVisionModels() async throws -> [String] {
        var tagsRequest = URLRequest(url: Self.endpoint.appendingPathComponent("api/tags"))
        tagsRequest.timeoutInterval = 2
        let (tagsData, tagsResponse) = try await session.data(for: tagsRequest)
        guard let http = tagsResponse as? HTTPURLResponse, http.statusCode == 200 else {
            throw CharacterSheetAnalysisError.localVisionUnavailable
        }
        let entries = try Self.modelEntries(from: tagsData)
        var visionModels: [String] = []
        for entry in entries {
            if let capabilities = entry.capabilities {
                if capabilities.contains("vision") { visionModels.append(entry.name) }
                continue
            }
            var showRequest = URLRequest(url: Self.endpoint.appendingPathComponent("api/show"))
            showRequest.httpMethod = "POST"
            showRequest.timeoutInterval = 5
            showRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            showRequest.httpBody = try JSONSerialization.data(withJSONObject: ["model": entry.name])
            guard let (data, response) = try? await session.data(for: showRequest),
                  let showHTTP = response as? HTTPURLResponse,
                  showHTTP.statusCode == 200 else { continue }
            if (try? Self.capabilities(from: data).contains("vision")) == true {
                visionModels.append(entry.name)
            }
        }
        return visionModels.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func modelNames(from data: Data) throws -> [String] {
        try modelEntries(from: data).map(\.name)
    }

    static func modelEntries(from data: Data) throws -> [ModelEntry] {
        struct Tags: Decodable {
            struct Model: Decodable {
                var name: String?
                var model: String?
                var capabilities: [String]?
            }
            var models: [Model]
        }
        return try JSONDecoder().decode(Tags.self, from: data).models.compactMap { model in
            guard let name = (model.name ?? model.model)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return nil }
            return ModelEntry(name: name, capabilities: model.capabilities.map(Set.init))
        }
    }

    static func capabilities(from data: Data) throws -> Set<String> {
        struct Show: Decodable { var capabilities: [String]? }
        return Set(try JSONDecoder().decode(Show.self, from: data).capabilities ?? [])
    }
}

final class CharacterSheetVisionEnvironmentService {
    static let modelUserDefaultsKey = "characterSheetVisionModel"
    private let userDefaults: UserDefaults
    private let client: CharacterSheetVisionEnvironmentClient

    init(userDefaults: UserDefaults = .standard,
         client: CharacterSheetVisionEnvironmentClient = OllamaCharacterSheetVisionEnvironmentClient()) {
        self.userDefaults = userDefaults
        self.client = client
    }

    func refresh(mode requested: CharacterSheetAnalysisMode? = nil) async -> CharacterSheetVisionSnapshot {
        let mode = requested ?? CharacterSheetAnalysisMode.selected(userDefaults: userDefaults)
        let configured = userDefaults.string(forKey: Self.modelUserDefaultsKey)?.trimmed.nilIfEmpty
        guard mode != .manual else {
            return CharacterSheetVisionSnapshot(requestedMode: mode, effectiveMode: .manual,
                                                installedVisionModels: [], configuredModel: configured,
                                                effectiveModel: nil, fallbackReason: nil)
        }
        let installed: [String]
        do { installed = try await client.installedVisionModels() }
        catch {
            return CharacterSheetVisionSnapshot(requestedMode: mode, effectiveMode: .manual,
                                                installedVisionModels: [], configuredModel: configured,
                                                effectiveModel: nil, fallbackReason: "localVisionUnavailable")
        }
        if let configured, installed.contains(configured) {
            return CharacterSheetVisionSnapshot(requestedMode: mode, effectiveMode: .localVision,
                                                installedVisionModels: installed, configuredModel: configured,
                                                effectiveModel: configured, fallbackReason: nil)
        }
        if mode == .localVision, configured != nil {
            return CharacterSheetVisionSnapshot(requestedMode: mode, effectiveMode: .manual,
                                                installedVisionModels: installed, configuredModel: configured,
                                                effectiveModel: nil, fallbackReason: "configuredVisionModelMissing")
        }
        if let first = installed.first {
            return CharacterSheetVisionSnapshot(requestedMode: mode, effectiveMode: .localVision,
                                                installedVisionModels: installed, configuredModel: configured,
                                                effectiveModel: first, fallbackReason: nil)
        }
        return CharacterSheetVisionSnapshot(requestedMode: mode, effectiveMode: .manual,
                                            installedVisionModels: [], configuredModel: configured,
                                            effectiveModel: nil, fallbackReason: "noCompatibleVisionModel")
    }
}

// MARK: - Provider and analyzer

protocol CharacterSheetVisionProvider {
    var name: String { get }
    var modelIdentifier: String? { get }
    func isAvailable() async -> Bool
    func complete(
        imageData: Data,
        system: String,
        prompt: String,
        outputSchema: [String: Any]
    ) async throws -> String
    func terminate() async
}

final class OllamaCharacterSheetVisionProvider: CharacterSheetVisionProvider {
    let name = "ollama"
    let modelIdentifier: String?
    private let baseURL: URL
    private let session: URLSession

    init(model: String,
         baseURL: URL = OllamaCharacterSheetVisionEnvironmentClient.endpoint,
         session: URLSession = .shared) {
        modelIdentifier = model
        self.baseURL = baseURL
        self.session = session
    }

    func isAvailable() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 2
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    func complete(
        imageData: Data,
        system: String,
        prompt: String,
        outputSchema: [String: Any]
    ) async throws -> String {
        guard let modelIdentifier else { throw CharacterSheetAnalysisError.localVisionUnavailable }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.requestPayload(
            model: modelIdentifier, imageData: imageData, system: system,
            prompt: prompt, outputSchema: outputSchema
        ))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CharacterSheetAnalysisError.localVisionUnavailable
        }
        return try OllamaDirectorProvider.completionText(from: data)
    }

    static func requestPayload(
        model: String,
        imageData: Data,
        system: String,
        prompt: String,
        outputSchema: [String: Any] = CharacterSheetAnalyzer.outputSchema
    ) -> [String: Any] {
        [
            "model": model,
            "system": system,
            "prompt": prompt,
            "images": [imageData.base64EncodedString()],
            "stream": false,
            "think": false,
            "format": outputSchema,
        ]
    }

    func terminate() async {
        guard let modelIdentifier else { return }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": modelIdentifier, "keep_alive": 0,
        ])
        _ = try? await session.data(for: request)
    }
}

enum CharacterSheetAnalysisError: Error, Equatable, LocalizedError {
    case localVisionUnavailable
    case generationInProgress
    case emptyResponse
    case invalidJSON(String)
    case invalidSchema(String)
    case analysisFailed(String)
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .localVisionUnavailable: return "Local analysis is unavailable. You can enter character details manually."
        case .generationInProgress: return "Character Sheet analysis is unavailable while video generation is active."
        case .emptyResponse: return "Local analysis returned no result."
        case .invalidJSON(let message), .invalidSchema(let message), .analysisFailed(let message): return message
        case .invalidImage: return "The selected image could not be prepared for local analysis."
        }
    }
}

final class CharacterSheetAnalyzer {
    enum FailureStage: String, Equatable {
        case unavailable, request, emptyResponse, extraction, syntax, decode, repair, retry, generationActive
    }
    struct Diagnostic: Equatable { var stage: FailureStage; var attempt: Int; var message: String }

    static let systemPrompt = """
    You analyze a fictional character reference sheet. Describe only visual information supported by the image. Do not invent personality, speaking style, biography, ethnicity, occupation, nationality, relationships, or story details. A section label such as FRONT, SIDE, BACK, CLOSE-UP, EXPRESSIONS, COSTUME DETAILS, or CHARACTER REFERENCE SHEET is not a character name. Return ONLY this JSON object:
    {"nameCandidate":"explicit title or empty","appearance":{"faceDescription":"","hair":"","eyes":"","ageImpression":"","build":"","complexion":"","distinguishingFeatures":"","generalNotes":""},"defaultCostumeDescription":"","accessories":[],"detectedViews":["front|side|back|closeUp|expression|costumeDetail|unknown"],"expressions":[],"continuitySuggestions":[],"uncertainties":[]}
    Use empty strings/arrays for unsupported observations. Do not output confidence numbers.
    """

    static let outputSchema: [String: Any] = {
        let string: [String: Any] = ["type": "string"]
        let stringArray: [String: Any] = ["type": "array", "items": string]
        let appearanceFields = [
            "faceDescription", "hair", "eyes", "ageImpression", "build",
            "complexion", "distinguishingFeatures", "generalNotes",
        ]
        let appearanceProperties = Dictionary(uniqueKeysWithValues: appearanceFields.map { ($0, string) })
        let appearance: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": appearanceProperties,
            "required": appearanceFields,
        ]
        let viewItems: [String: Any] = [
            "type": "string",
            "enum": ["front", "side", "back", "closeUp", "expression", "costumeDetail", "unknown"],
        ]
        let properties: [String: Any] = [
            "nameCandidate": string,
            "appearance": appearance,
            "defaultCostumeDescription": string,
            "accessories": stringArray,
            "detectedViews": ["type": "array", "items": viewItems],
            "expressions": stringArray,
            "continuitySuggestions": stringArray,
            "uncertainties": stringArray,
        ]
        return [
            "type": "object",
            "additionalProperties": false,
            "properties": properties,
            "required": [
                "nameCandidate", "appearance", "defaultCostumeDescription", "accessories",
                "detectedViews", "expressions", "continuitySuggestions", "uncertainties",
            ],
        ]
    }()

    private let provider: CharacterSheetVisionProvider
    private let generationIsActive: () async -> Bool
    private(set) var diagnostics: [Diagnostic] = []

    init(provider: CharacterSheetVisionProvider,
         generationIsActive: @escaping () async -> Bool = { false }) {
        self.provider = provider
        self.generationIsActive = generationIsActive
    }

    func analyze(imageData: Data, sourceAssetID: UUID) async throws -> CharacterSheetAnalysisCandidate {
        diagnostics = []
        let generationActive = await generationIsActive()
        guard !generationActive else {
            diagnostics.append(.init(stage: .generationActive, attempt: 0, message: "video generation active"))
            throw CharacterSheetAnalysisError.generationInProgress
        }
        guard await provider.isAvailable() else {
            diagnostics.append(.init(stage: .unavailable, attempt: 0, message: "provider unavailable"))
            throw CharacterSheetAnalysisError.localVisionUnavailable
        }

        var lastError: Error = CharacterSheetAnalysisError.analysisFailed("Local analysis failed.")
        var previousInvalidResponse: String?
        for attempt in 0...1 {
            do {
                let prompt: String
                if attempt == 0 {
                    prompt = "Analyze this Character Sheet and return the required JSON only."
                } else {
                    let previous = String((previousInvalidResponse ?? "No completion text was returned.").prefix(8_000))
                    prompt = """
                    Rewrite the previous invalid output into the required JSON schema. Preserve only observations supported by the image and previous output. Return the JSON object only.
                    PREVIOUS INVALID OUTPUT:
                    \(previous)
                    """
                }
                let response = try await provider.complete(
                    imageData: imageData,
                    system: Self.systemPrompt,
                    prompt: prompt,
                    outputSchema: Self.outputSchema
                )
                previousInvalidResponse = response
                let parsed = try Self.parse(response: response, sourceAssetID: sourceAssetID,
                                            provider: provider.name, model: provider.modelIdentifier)
                await provider.terminate()
                return parsed
            } catch {
                lastError = error
                let stage: FailureStage
                switch error {
                case CharacterSheetAnalysisError.emptyResponse: stage = .emptyResponse
                case CharacterSheetAnalysisError.invalidJSON: stage = .syntax
                case CharacterSheetAnalysisError.invalidSchema: stage = .decode
                default: stage = .request
                }
                diagnostics.append(.init(stage: stage, attempt: attempt, message: error.localizedDescription))
                if attempt == 0 { diagnostics.append(.init(stage: .repair, attempt: attempt, message: "one bounded repair requested")) }
                else { diagnostics.append(.init(stage: .retry, attempt: attempt, message: "repair exhausted")) }
            }
        }
        await provider.terminate()
        throw lastError
    }

    static func parse(
        response: String,
        sourceAssetID: UUID,
        provider: String,
        model: String?
    ) throws -> CharacterSheetAnalysisCandidate {
        guard !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CharacterSheetAnalysisError.emptyResponse
        }
        let candidates = StructuredJSONUtilities.objectCandidates(from: response)
        guard !candidates.isEmpty,
              StructuredJSONUtilities.firstJSONObject(in: response) != nil || response.trimmed.hasPrefix("{") else {
            throw CharacterSheetAnalysisError.invalidJSON("No balanced JSON object was found in the local analysis result.")
        }
        var lastError = "Character Sheet result did not match the required schema."
        for candidate in candidates {
            let repaired = StructuredJSONUtilities.removingTrailingCommas(from: candidate)
            guard let data = repaired.data(using: .utf8) else { continue }
            let object: Any
            do { object = try JSONSerialization.jsonObject(with: data) }
            catch { lastError = "Character Sheet result contained invalid JSON."; continue }
            guard var dictionary = object as? [String: Any] else { continue }
            for wrapper in ["candidate", "character", "analysis"] {
                if dictionary["appearance"] == nil, let nested = dictionary[wrapper] as? [String: Any] {
                    dictionary = nested
                }
            }
            dictionary = normalize(dictionary)
            do {
                let normalizedData = try JSONSerialization.data(withJSONObject: dictionary)
                let wire = try JSONDecoder().decode(WireCandidate.self, from: normalizedData)
                return CharacterSheetAnalysisCandidate(
                    sourceAssetID: sourceAssetID,
                    nameCandidate: Self.sanitizedNameCandidate(wire.nameCandidate),
                    appearance: wire.appearance,
                    defaultCostumeDescription: wire.defaultCostumeDescription,
                    accessories: wire.accessories.joined(separator: ", "),
                    detectedViews: wire.detectedViews.map(DetectedCharacterView.init(rawValue:)),
                    expressions: wire.expressions,
                    continuitySuggestions: wire.continuitySuggestions,
                    uncertainties: wire.uncertainties,
                    provider: provider,
                    model: model
                )
            } catch { lastError = "Character Sheet result was missing its required appearance structure." }
        }
        throw CharacterSheetAnalysisError.invalidSchema(lastError)
    }

    private struct WireCandidate: Decodable {
        var nameCandidate: String
        var appearance: CharacterAppearance
        var defaultCostumeDescription: String
        var accessories: [String]
        var detectedViews: [String]
        var expressions: [String]
        var continuitySuggestions: [String]
        var uncertainties: [String]

        private enum CodingKeys: String, CodingKey {
            case nameCandidate, appearance, defaultCostumeDescription, accessories,
                 detectedViews, expressions, continuitySuggestions, uncertainties
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            nameCandidate = try container.decodeIfPresent(String.self, forKey: .nameCandidate) ?? ""
            appearance = try container.decode(CharacterAppearance.self, forKey: .appearance)
            defaultCostumeDescription = try container.decodeIfPresent(String.self, forKey: .defaultCostumeDescription) ?? ""
            accessories = try container.decodeIfPresent([String].self, forKey: .accessories) ?? []
            detectedViews = try container.decodeIfPresent([String].self, forKey: .detectedViews) ?? []
            expressions = try container.decodeIfPresent([String].self, forKey: .expressions) ?? []
            continuitySuggestions = try container.decodeIfPresent([String].self, forKey: .continuitySuggestions) ?? []
            uncertainties = try container.decodeIfPresent([String].self, forKey: .uncertainties) ?? []
        }
    }

    /// Sheet section labels a vision model sometimes returns as the character's
    /// name, because they are the largest text on the image.
    ///
    /// `systemPrompt` already says these are not names, but an instruction is
    /// not an enforcement mechanism: a local model returned exactly
    /// "Character Reference Sheet" (while its own uncertainties field warned
    /// that the sheet's titles "may be interpreted as character names"). That
    /// name then became the character's identity everywhere, including the
    /// literal render prompt "CHARACTER 1: Character Reference Sheet." An
    /// empty name is strictly better: the review UI already offers the name
    /// field for editing whenever it is blank (see
    /// `CharacterSheetFieldSelection.defaults(for:)`), so the user is asked
    /// instead of being handed a label.
    static let sheetLabelNames: Set<String> = [
        "character reference sheet", "character sheet", "reference sheet",
        "characterreferencesheet", "charactersheet", "referencesheet",
        "character", "reference", "sheet", "model sheet", "modelsheet",
        "turnaround", "character turnaround", "front", "side", "back",
        "close-up", "close up", "closeup", "expressions", "expression",
        "costume details", "costume detail", "costume", "views", "view",
        "face", "details", "detail",
        "untitled", "unknown", "n/a", "na", "none",
    ]

    /// Case-folds and strips punctuation the same way for both the whole
    /// candidate and each comma/slash-split segment, so "CHARACTER REFERENCE
    /// SHEET:", "Character-Reference-Sheet" and "Costume Detail" all collapse
    /// onto the keys in `sheetLabelNames`.
    private static func foldedLabel(_ s: some StringProtocol) -> String {
        s.lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .split(separator: " ")
            .joined(separator: " ")
    }

    private static func isKnownSheetLabel(_ folded: String) -> Bool {
        !folded.isEmpty
            && (sheetLabelNames.contains(folded)
                || sheetLabelNames.contains(folded.replacingOccurrences(of: " ", with: "")))
    }

    static func sanitizedNameCandidate(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let folded = foldedLabel(trimmed)
        guard !folded.isEmpty else { return "" }
        if isKnownSheetLabel(folded) { return "" }

        // A vision model sometimes returns the sheet's own detected-view list
        // instead of a name -- "Front, Side, Back, Expressions, Details" is not
        // one label a user typed, it is several, joined the way the sheet UI
        // joins them. No single-segment exact match catches that, so split on
        // the same separators the sheet uses and check whether every segment
        // is itself a known label. Two or more matching segments is required:
        // one segment is exactly the whole-candidate case already handled
        // above, and a single overlapping word must never cost a real name
        // ("Reference Rita", "Back Taylor") its segment count is 1 either way.
        let segments = trimmed
            .split(whereSeparator: { $0 == "," || $0 == "/" })
            .map { foldedLabel($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
        if segments.count >= 2, segments.allSatisfy(isKnownSheetLabel) {
            return ""
        }

        return trimmed
    }

    private static func normalize(_ source: [String: Any]) -> [String: Any] {
        var root = source
        if root["nameCandidate"] == nil { root["nameCandidate"] = root["name"] ?? "" }
        if root["defaultCostumeDescription"] == nil {
            root["defaultCostumeDescription"] = root["defaultCostume"] ?? root["costume"] ?? ""
        }
        if root["detectedViews"] == nil { root["detectedViews"] = root["views"] ?? [] }
        if let accessories = root["accessories"] as? String { root["accessories"] = [accessories] }
        for key in ["accessories", "detectedViews", "expressions", "continuitySuggestions", "uncertainties"]
        where root[key] == nil { root[key] = [] }

        if root["appearance"] == nil {
            let appearanceKeys = ["faceDescription", "hair", "eyes", "ageImpression", "build",
                                  "complexion", "distinguishingFeatures", "generalNotes"]
            var appearance: [String: Any] = [:]
            for key in appearanceKeys where root[key] != nil { appearance[key] = root[key] }
            if !appearance.isEmpty { root["appearance"] = appearance }
        }
        return root
    }
}

// MARK: - Analysis image derivative

enum CharacterSheetImagePreprocessor {
    /// Original project asset remains untouched. The returned temporary JPEG
    /// is bounded for unified-memory use while retaining sheet text/details.
    static func analysisData(from url: URL, maxPixelDimension: Int = 2048) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw CharacterSheetAnalysisError.invalidImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw CharacterSheetAnalysisError.invalidImage
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw CharacterSheetAnalysisError.invalidImage }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.9,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CharacterSheetAnalysisError.invalidImage
        }
        return data as Data
    }

    static func pixelSize(of url: URL) -> (width: Int?, height: Int?) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return (nil, nil)
        }
        return ((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension FilmProjectStore.StoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .schemaTooNew(let version): return "Project schema \(version) is newer than this app supports."
        case .projectNotFound: return "Project was not found."
        case .unsupportedCharacterSheetFormat: return "Choose a PNG, JPG, or JPEG Character Sheet."
        case .invalidCharacterSheetSource: return "The selected Character Sheet could not be read."
        case .invalidManagedAssetPath: return "The managed Character Sheet path is invalid."
        case .unsupportedOpeningReferenceFormat: return "Choose a PNG, JPG, or JPEG image for the opening reference."
        case .invalidOpeningReferenceSource: return "The selected opening reference image could not be read."
        case .unsupportedFinalBGMFormat: return "Choose an MP3, WAV, M4A, or AAC file for the Final Audio BGM."
        case .invalidFinalBGMSource: return "The selected BGM file could not be read."
        }
    }
}
