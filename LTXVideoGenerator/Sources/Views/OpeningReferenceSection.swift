import SwiftUI
import UniformTypeIdentifiers

/// Scene-like still used as the first frame of an Auto Movie's opening shot.
///
/// Distinct from the Character Anchor below it: this is "start the movie from
/// this frame", not "use this Character Bible asset". The copy says which one
/// wins when both are set, because the difference is not obvious from the
/// controls alone.
struct OpeningReferenceSection: View {
    let project: FilmProject
    let onChanged: () -> Void

    private let store = FilmProjectStore.shared
    @State private var importError: String?

    private var reference: OpeningReferenceImage? { project.openingReferenceImage }

    private var resolvedURL: URL? {
        guard case .success(let url)? = CharacterAnchorResolver.resolveOpeningReference(
            project: project, store: store) else { return nil }
        return url
    }

    private var isMissing: Bool {
        if case .failure? = CharacterAnchorResolver.resolveOpeningReference(
            project: project, store: store) { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "film.stack")
                    .foregroundStyle(.secondary)
                Text("Movie Settings — Opening Reference Image").font(.headline)
            }
            Text("Applies to this Auto Movie as a whole, not to any single shot below. Chosen when the movie is created; change it here to affect future renders of the first shot.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Button(reference == nil ? "Choose Image…" : "Replace…") { choose() }
                        if reference != nil {
                            Button("Clear", role: .destructive) { clear() }
                        }
                    }
                    if let name = reference?.originalFilename {
                        Text(name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    // What the app actually read out of this image. Shown
                    // because the character description used for every shot now
                    // comes from here rather than from a guess.
                    if reference != nil, let appearance = project.openingReferenceAppearance {
                        Label(
                            "Opening appearance: \(appearance.statusDescription)",
                            systemImage: appearance.isUsable
                                ? "checkmark.circle" : "info.circle"
                        )
                        .font(.caption2)
                        .foregroundStyle(appearance.isUsable ? .green : .secondary)
                        if appearance.isUsable, !appearance.costumeSummary.isEmpty {
                            Text(appearance.costumeSummary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    // Character/Opening consistency now has its own section,
                    // shown above Planned Shots rather than buried here — see
                    // CharacterOpeningConsistencySection.
                    if isMissing {
                        Label(OpeningReferenceIssue.fileMissing.message,
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Text("Generation is blocked until this is replaced or cleared.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let importError {
                        Text(importError).font(.caption).foregroundStyle(.red)
                    }
                }
                Spacer()
                preview
            }

            OpeningReferenceExplanation()
            if let recommendation = MiniMaxH3ProductPolicy.recommendation(
                modelID: project.settings.modelID,
                context: .autoMovie,
                hasImage: reference != nil
            ) {
                MiniMaxH3ImageGroundingRecommendationView(recommendation: recommendation)
            }
            if reference != nil && project.characterAnchor.isActive {
                Text("Both are set: the opening reference image is used for the first shot, and the Character Anchor is not.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    @ViewBuilder
    private var preview: some View {
        if let resolvedURL, let image = NSImage(contentsOf: resolvedURL) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 128, height: 86)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                .accessibilityLabel("Opening reference image preview")
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.12))
                .frame(width: 128, height: 86)
                .overlay(Image(systemName: isMissing ? "exclamationmark.triangle" : "photo")
                    .foregroundStyle(isMissing ? .orange : .secondary))
        }
    }

    // MARK: - Actions

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Use Image"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importError = nil
        do {
            let imported = try store.importOpeningReferenceImage(from: url, projectID: project.id)
            guard var stored = store.project(id: project.id) else { return }
            // Replacing removes the copy it supersedes so the project does not
            // accumulate orphaned stills. The user's original is never touched.
            if let previous = stored.openingReferenceImage {
                if let sourceURL = store.managedProjectAssetURL(
                    projectID: project.id, relativePath: previous.projectRelativePath
                ) {
                    ImageConditioningPreparer.shared.invalidate(sourceURL: sourceURL)
                }
                store.removeManagedOpeningReference(projectID: project.id, reference: previous)
            }
            stored.openingReferenceImage = imported
            OpeningReferenceSync.invalidateIfStale(project: &stored)
            OpeningReferenceSync.evaluateConsistency(project: &stored)
            IdentityRefreshService.invalidateOpeningReferenceAnchors(in: &stored)
            store.save(stored)
            onChanged()
        } catch {
            importError = (error as? LocalizedError)?.errorDescription
                ?? "Could not import that image."
        }
    }

    private func clear() {
        guard var stored = store.project(id: project.id),
              let existing = stored.openingReferenceImage else { return }
        if let sourceURL = store.managedProjectAssetURL(
            projectID: project.id, relativePath: existing.projectRelativePath
        ) {
            ImageConditioningPreparer.shared.invalidate(sourceURL: sourceURL)
        }
        store.removeManagedOpeningReference(projectID: project.id, reference: existing)
        stored.openingReferenceImage = nil
        OpeningReferenceSync.invalidateIfStale(project: &stored)
        IdentityRefreshService.invalidateOpeningReferenceAnchors(in: &stored)
        store.save(stored)
        onChanged()
    }
}
