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
            Text("Opening Reference Image (Optional)").font(.headline)

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

            Text("Use a scene-like image as the visual starting point for the first Auto Movie shot. Later shots continue from the previous shot.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("For best results, use an image that already contains the intended character, clothing, and scene. Character sheets and plain reference plates may appear directly in the opening frame.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("映画のワンシーンのような画像を、Auto Movieの1本目の開始画像として使用します。以降のショットは前の映像を引き継ぎます。")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("人物・服装・背景がすでにシーンとして成立している画像がおすすめです。キャラクターシートや白背景の参照画像は、そのまま開始フレームに現れる場合があります。")
                .font(.caption2)
                .foregroundStyle(.secondary)
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
                store.removeManagedOpeningReference(projectID: project.id, reference: previous)
            }
            stored.openingReferenceImage = imported
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
        store.removeManagedOpeningReference(projectID: project.id, reference: existing)
        stored.openingReferenceImage = nil
        store.save(stored)
        onChanged()
    }
}
