import Foundation

/// Versioned, crash-safe persistence for FilmProjects.
/// One JSON file per project under Application Support/LocalVideoStudio(Dev)/Projects.
/// Writes are atomic; schema migrations keep a backup of the pre-migration file.
final class FilmProjectStore {
    static let shared = FilmProjectStore()

    enum StoreError: Error, Equatable {
        case schemaTooNew(Int)
        case projectNotFound(UUID)
        case unsupportedCharacterSheetFormat(String)
        case invalidCharacterSheetSource
        case unsupportedOpeningReferenceFormat(String)
        case invalidOpeningReferenceSource
        case invalidManagedAssetPath
        case unsupportedFinalBGMFormat(String)
        case invalidFinalBGMSource
        case unsupportedNewStartFrameFormat(String)
        case invalidNewStartFrameSource
    }

    let projectsDirectory: URL
    private(set) var projects: [UUID: FilmProject] = [:]

    init(projectsDirectory: URL? = nil) {
        if let projectsDirectory {
            self.projectsDirectory = projectsDirectory
        } else {
            self.projectsDirectory = AppStorageDirectory.projectsDirectory
        }
        try? FileManager.default.createDirectory(at: self.projectsDirectory, withIntermediateDirectories: true)
        loadAll()
    }

    private func fileURL(for id: UUID) -> URL {
        projectsDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    /// Canonical ownership boundary for future Character Sheet imports.
    /// Phase 0 does not copy/analyze files, but all future imports have a
    /// project-managed destination instead of persisting fragile external
    /// absolute paths.
    func characterAssetsDirectory(projectID: UUID, characterID: UUID) -> URL {
        projectsDirectory
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
            .appendingPathComponent("Assets", isDirectory: true)
            .appendingPathComponent("Characters", isDirectory: true)
            .appendingPathComponent(characterID.uuidString, isDirectory: true)
    }

    /// Continuity frames inherited between shots live beside character assets
    /// inside the project, so they survive relaunch and are removed with the
    /// project instead of leaking into a temporary directory.
    func continuityAssetsDirectory(projectID: UUID) -> URL {
        projectsDirectory
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
            .appendingPathComponent("Assets", isDirectory: true)
            .appendingPathComponent("Continuity", isDirectory: true)
    }

    /// Opening reference stills live beside the other project-owned assets so
    /// they survive relaunch and are removed with the project.
    func openingReferenceDirectory(projectID: UUID) -> URL {
        projectsDirectory
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
            .appendingPathComponent("Assets", isDirectory: true)
            .appendingPathComponent("OpeningReference", isDirectory: true)
    }

    /// Copies a PNG/JPG/JPEG into the project as its Opening Reference Image.
    ///
    /// Mirrors `importCharacterSheet` exactly — copy to a temporary name, then
    /// atomically move into a UUID filename — so the external original is never
    /// moved, renamed or persisted as an absolute path, and a failed import
    /// cannot leave a half-written file where the project expects an image.
    func importOpeningReferenceImage(
        from sourceURL: URL,
        projectID: UUID
    ) throws -> OpeningReferenceImage {
        let source = sourceURL.standardizedFileURL
        let ext = source.pathExtension.lowercased()
        guard ["png", "jpg", "jpeg"].contains(ext) else {
            throw StoreError.unsupportedOpeningReferenceFormat(ext)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw StoreError.invalidOpeningReferenceSource
        }

        let directory = openingReferenceDirectory(projectID: projectID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = "opening-reference-\(UUID().uuidString).\(ext)"
        let destination = directory.appendingPathComponent(filename)
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).importing")
        do {
            try FileManager.default.copyItem(at: source, to: temporary)
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw CocoaError(.fileWriteFileExists)
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            try? FileManager.default.removeItem(at: destination)
            throw error
        }

        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        return OpeningReferenceImage(
            projectRelativePath: "Assets/OpeningReference/\(filename)",
            originalFilename: source.lastPathComponent,
            mimeType: ext == "png" ? "image/png" : "image/jpeg",
            fileSizeBytes: size
        )
    }

    /// Removes only the project-owned copy. Replacing an image deletes the copy
    /// it supersedes so the directory does not accumulate orphans; the user's
    /// original is outside this ownership boundary and is never touched.
    func removeManagedOpeningReference(projectID: UUID, reference: OpeningReferenceImage) {
        guard let url = managedProjectAssetURL(
            projectID: projectID, relativePath: reference.projectRelativePath) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// A Cut shot's explicit New Start Frame lives beside the other
    /// project-owned assets, one subdirectory per shot, so it survives
    /// relaunch and is removed with the project.
    func newStartFrameDirectory(projectID: UUID, shotID: UUID) -> URL {
        projectsDirectory
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
            .appendingPathComponent("Assets", isDirectory: true)
            .appendingPathComponent("NewStartFrame", isDirectory: true)
            .appendingPathComponent(shotID.uuidString, isDirectory: true)
    }

    /// Copies a PNG/JPG/JPEG into the project as a shot's explicit New Start
    /// Frame — the image a Cut shot starts from instead of the previous
    /// shot's final frame.
    ///
    /// Mirrors `importOpeningReferenceImage`: copy to a temporary name, then
    /// atomically move into a UUID filename, so the external original is
    /// never moved, renamed or persisted as an absolute path, and a failed
    /// import cannot leave a half-written file where the shot expects an
    /// image. Returns the project-relative path to store on
    /// `Shot.newStartFrameRelativePath`.
    func importNewStartFrame(
        from sourceURL: URL,
        projectID: UUID,
        shotID: UUID
    ) throws -> String {
        let source = sourceURL.standardizedFileURL
        let ext = source.pathExtension.lowercased()
        guard ["png", "jpg", "jpeg"].contains(ext) else {
            throw StoreError.unsupportedNewStartFrameFormat(ext)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw StoreError.invalidNewStartFrameSource
        }

        let directory = newStartFrameDirectory(projectID: projectID, shotID: shotID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = "new-start-\(UUID().uuidString).\(ext)"
        let destination = directory.appendingPathComponent(filename)
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).importing")
        do {
            try FileManager.default.copyItem(at: source, to: temporary)
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw CocoaError(.fileWriteFileExists)
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            try? FileManager.default.removeItem(at: destination)
            throw error
        }

        return "Assets/NewStartFrame/\(shotID.uuidString)/\(filename)"
    }

    /// Removes only the project-owned copy. Replacing/clearing the New Start
    /// Frame deletes the copy it supersedes so the directory does not
    /// accumulate orphans; the user's original is outside this ownership
    /// boundary and is never touched.
    func removeManagedNewStartFrame(projectID: UUID, relativePath: String) {
        guard let url = managedProjectAssetURL(
            projectID: projectID, relativePath: relativePath) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// The imported Global BGM file lives beside the other project-owned
    /// assets so it survives relaunch and is removed with the project.
    func finalAudioDirectory(projectID: UUID) -> URL {
        projectsDirectory
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
            .appendingPathComponent("Assets", isDirectory: true)
            .appendingPathComponent("FinalAudio", isDirectory: true)
    }

    /// Copies an MP3/WAV/M4A/AAC file into the project as its Global BGM
    /// asset. Mirrors `importOpeningReferenceImage`: copy to a temporary name,
    /// then atomically move into a UUID filename, so the external original is
    /// never moved or persisted as an absolute path, and a failed import
    /// cannot leave a half-written file where the project expects audio.
    func importFinalAudioAsset(from sourceURL: URL, projectID: UUID) throws -> FinalAudioAsset {
        let source = sourceURL.standardizedFileURL
        let ext = source.pathExtension.lowercased()
        let mimeType: String
        switch ext {
        case "mp3": mimeType = "audio/mpeg"
        case "wav": mimeType = "audio/wav"
        case "m4a": mimeType = "audio/mp4"
        case "aac": mimeType = "audio/aac"
        default:
            throw StoreError.unsupportedFinalBGMFormat(ext)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw StoreError.invalidFinalBGMSource
        }

        let directory = finalAudioDirectory(projectID: projectID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = "bgm-\(UUID().uuidString).\(ext)"
        let destination = directory.appendingPathComponent(filename)
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).importing")
        do {
            try FileManager.default.copyItem(at: source, to: temporary)
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw CocoaError(.fileWriteFileExists)
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            try? FileManager.default.removeItem(at: destination)
            throw error
        }

        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        return FinalAudioAsset(
            projectRelativePath: "Assets/FinalAudio/\(filename)",
            originalFilename: source.lastPathComponent,
            mimeType: mimeType,
            fileSizeBytes: size
        )
    }

    /// Removes only the project-owned copy. Replacing/removing the BGM deletes
    /// the copy it supersedes so the directory does not accumulate orphans.
    func removeManagedFinalAudioAsset(projectID: UUID, asset: FinalAudioAsset) {
        guard let url = managedProjectAssetURL(
            projectID: projectID, relativePath: asset.projectRelativePath) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func importFinalAmbienceAsset(from sourceURL: URL, projectID: UUID) throws -> FinalAudioAsset {
        let source = sourceURL.standardizedFileURL
        let ext = source.pathExtension.lowercased()
        let mimeType: String
        switch ext {
        case "mp3": mimeType = "audio/mpeg"
        case "wav": mimeType = "audio/wav"
        case "m4a": mimeType = "audio/mp4"
        case "aac": mimeType = "audio/aac"
        default:
            throw StoreError.unsupportedFinalBGMFormat(ext)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw StoreError.invalidFinalBGMSource
        }

        let directory = finalAudioDirectory(projectID: projectID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = "ambience-\(UUID().uuidString).\(ext)"
        let destination = directory.appendingPathComponent(filename)
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).importing")
        do {
            try FileManager.default.copyItem(at: source, to: temporary)
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw CocoaError(.fileWriteFileExists)
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            try? FileManager.default.removeItem(at: destination)
            throw error
        }

        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        return FinalAudioAsset(
            projectRelativePath: "Assets/FinalAudio/\(filename)",
            originalFilename: source.lastPathComponent,
            mimeType: mimeType,
            fileSizeBytes: size
        )
    }

    func removeManagedFinalAmbienceAsset(projectID: UUID, asset: FinalAudioAsset) {
        removeManagedFinalAudioAsset(projectID: projectID, asset: asset)
    }

    /// Resolves any project-relative asset path, refusing absolute paths and
    /// anything that escapes the project directory.
    func managedProjectAssetURL(projectID: UUID, relativePath: String) -> URL? {
        managedCharacterAssetURL(projectID: projectID, relativePath: relativePath)
    }

    func managedCharacterAssetURL(projectID: UUID, relativePath: String) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return nil }
        let root = projectsDirectory
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
            .standardizedFileURL
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(prefix) else { return nil }
        return candidate
    }

    /// Copies a PNG/JPG/JPEG into the FilmProject-owned character asset tree.
    /// The external source is never moved, renamed, modified, or persisted as
    /// an absolute path. A UUID filename prevents collisions and silent
    /// overwrites. The asset record is returned only after the atomic move.
    func importCharacterSheet(
        from sourceURL: URL,
        projectID: UUID,
        characterID: UUID
    ) throws -> CharacterReferenceAsset {
        let source = sourceURL.standardizedFileURL
        let ext = source.pathExtension.lowercased()
        guard ["png", "jpg", "jpeg"].contains(ext) else {
            throw StoreError.unsupportedCharacterSheetFormat(ext)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw StoreError.invalidCharacterSheetSource
        }

        let directory = characterAssetsDirectory(projectID: projectID, characterID: characterID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = "character-sheet-\(UUID().uuidString).\(ext)"
        let destination = directory.appendingPathComponent(filename)
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).importing")
        do {
            try FileManager.default.copyItem(at: source, to: temporary)
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw CocoaError(.fileWriteFileExists)
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            try? FileManager.default.removeItem(at: destination)
            throw error
        }

        let relativePath = "Assets/Characters/\(characterID.uuidString)/\(filename)"
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        return CharacterReferenceAsset(
            type: .characterSheet,
            label: "Character Sheet",
            projectRelativePath: relativePath,
            originalFilename: source.lastPathComponent,
            mimeType: ext == "png" ? "image/png" : "image/jpeg",
            fileSizeBytes: size
        )
    }

    /// Removes only a validated project-owned file. External originals are
    /// outside this ownership boundary and can never be deleted here.
    func removeManagedCharacterAsset(projectID: UUID, asset: CharacterReferenceAsset) {
        guard let relativePath = asset.projectRelativePath,
              let url = managedCharacterAssetURL(projectID: projectID, relativePath: relativePath) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Character directories are UUID-owned and never shared by another
    /// BibleCharacter. Deleting this directory cannot affect the external
    /// originals from which its files were copied.
    func removeManagedCharacterAssets(projectID: UUID, characterID: UUID) {
        let directory = characterAssetsDirectory(projectID: projectID, characterID: characterID)
        try? FileManager.default.removeItem(at: directory)
    }

    /// New-project sheets may stage assets before planning creates the JSON.
    /// If that wizard is cancelled, remove only its uncommitted project tree.
    func removeUncommittedProjectAssets(projectID: UUID) {
        guard projects[projectID] == nil else { return }
        let directory = projectsDirectory.appendingPathComponent(projectID.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Load

    func loadAll() {
        projects = [:]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: projectsDirectory, includingPropertiesForKeys: nil
        )) ?? []
        for file in files where file.pathExtension == "json" {
            if let project = try? load(url: file) {
                projects[project.id] = project
            }
        }
    }

    private func load(url: URL) throws -> FilmProject {
        let data = try Data(contentsOf: url)
        // Peek schema version before full decode.
        if let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let version = raw["schemaVersion"] as? Int {
            if version > FilmProject.currentSchemaVersion {
                // Never destroy a newer file we can't understand.
                throw StoreError.schemaTooNew(version)
            }
            if version < FilmProject.currentSchemaVersion {
                // Future migrations hook in here. Keep a backup before touching.
                let backup = url.deletingPathExtension().appendingPathExtension("v\(version).bak.json")
                if !FileManager.default.fileExists(atPath: backup.path) {
                    try? data.write(to: backup, options: .atomic)
                }
            }
        }
        return try JSONDecoder().decode(FilmProject.self, from: data)
    }

    // MARK: Save

    func save(_ project: FilmProject) {
        try? saveThrowing(project)
    }

    /// Throwing boundary used when a managed file and its metadata must be
    /// committed as one user-visible operation. Existing callers retain the
    /// legacy best-effort `save` API.
    func saveThrowing(_ project: FilmProject) throws {
        var updated = project
        updated.touch()
        let data = try JSONEncoder().encode(updated)
        try data.write(to: fileURL(for: updated.id), options: .atomic)
        projects[updated.id] = updated
    }

    func delete(_ id: UUID) {
        projects[id] = nil
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }

    func project(id: UUID) -> FilmProject? {
        projects[id]
    }

    var allProjects: [FilmProject] {
        projects.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: Resume

    /// Reconciles in-flight takes after app restart. The actual MP4 on disk is
    /// the source of truth: a take whose file exists and probes valid becomes
    /// `completed` (with actual metadata filled); otherwise it returns to
    /// `queued` via `interrupted`.
    @discardableResult
    func reconcileInFlightTakes(projectID: UUID) -> Int {
        guard var project = projects[projectID] else { return 0 }
        var reconciled = 0
        for shotIndex in project.shots.indices {
            for takeIndex in project.shots[shotIndex].takes.indices {
                let take = project.shots[shotIndex].takes[takeIndex]
                guard take.status == .generating || take.status == .queued else { continue }
                reconciled += 1
                if let path = take.outputPath,
                   FileManager.default.fileExists(atPath: path),
                   let info = MediaProbe.probe(path: path),
                   info.width != nil, (info.durationSeconds ?? 0) > 0 {
                    project.shots[shotIndex].takes[takeIndex].status = .completed
                    project.shots[shotIndex].takes[takeIndex].actualWidth = info.width
                    project.shots[shotIndex].takes[takeIndex].actualHeight = info.height
                    project.shots[shotIndex].takes[takeIndex].actualDuration = info.durationSeconds
                    project.shots[shotIndex].takes[takeIndex].audioMetadata = info
                    if project.shots[shotIndex].takes[takeIndex].generationCompletedAt == nil {
                        project.shots[shotIndex].takes[takeIndex].generationCompletedAt = Date()
                    }
                } else {
                    project.shots[shotIndex].takes[takeIndex].status = .queued
                    project.shots[shotIndex].takes[takeIndex].generationStartedAt = nil
                }
            }
        }
        // Jobs mirroring take state.
        for jobIndex in project.jobs.indices where project.jobs[jobIndex].state == .running {
            project.jobs[jobIndex].state = .queued
            project.jobs[jobIndex].updatedAt = Date()
        }
        if reconciled > 0 { save(project) }
        return reconciled
    }
}
