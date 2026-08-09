import Foundation

/// Versioned, crash-safe persistence for FilmProjects.
/// One JSON file per project under Application Support/LTXVideoGenerator/Projects.
/// Writes are atomic; schema migrations keep a backup of the pre-migration file.
final class FilmProjectStore {
    static let shared = FilmProjectStore()

    enum StoreError: Error, Equatable {
        case schemaTooNew(Int)
        case projectNotFound(UUID)
        case unsupportedCharacterSheetFormat(String)
        case invalidCharacterSheetSource
        case invalidManagedAssetPath
    }

    let projectsDirectory: URL
    private(set) var projects: [UUID: FilmProject] = [:]

    init(projectsDirectory: URL? = nil) {
        if let projectsDirectory {
            self.projectsDirectory = projectsDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.projectsDirectory = appSupport
                .appendingPathComponent("LTXVideoGenerator", isDirectory: true)
                .appendingPathComponent("Projects", isDirectory: true)
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
