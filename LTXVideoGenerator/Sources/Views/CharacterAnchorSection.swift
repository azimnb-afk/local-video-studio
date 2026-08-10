import SwiftUI

/// Optional protagonist reference for an Auto Movie's opening shot.
///
/// Wording is deliberately grounded: this improves visual consistency, it does
/// not lock identity, and the copy says so in both languages. Later shots
/// continue from the previous shot and never see this image again.
struct CharacterAnchorSection: View {
    let project: FilmProject
    let onChanged: () -> Void

    private let store = FilmProjectStore.shared

    private var anchor: CharacterAnchor { project.characterAnchor }

    private var characters: [BibleCharacter] {
        project.characterBible.characters
    }

    private var selectedCharacter: BibleCharacter? {
        guard let id = anchor.characterID else { return nil }
        return characters.first { $0.id == id }
    }

    /// Character sheets are excluded: a multi-pose layout is not a frame a shot
    /// can begin on.
    private var selectableAssets: [CharacterReferenceAsset] {
        (selectedCharacter?.referenceAssets ?? []).filter { $0.isStartingImageCandidate }
    }

    private var issue: CharacterAnchorIssue? {
        CharacterAnchorResolver.issue(project: project, store: store)
    }

    private var previewURL: URL? {
        guard case .resolved(let resolved) = CharacterAnchorResolver.resolve(
            project: project, store: store) else { return nil }
        return resolved.fileURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { anchor.isEnabled },
                set: { setEnabled($0) }
            )) {
                Text("Character Anchor (Optional)").font(.headline)
            }
            .toggleStyle(.switch)
            .disabled(characters.isEmpty)

            if characters.isEmpty {
                Text("Add a character to this project's Character Bible to use a visual reference for the opening shot.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if anchor.isEnabled {
                configuration
            }

            Text("The selected reference image is used as the opening shot's first frame, so whatever it shows — including a plain background — appears there. Later shots continue from the previous shot. Visual consistency may improve, but exact identity is not guaranteed. For a cinematic opening, prefer an Opening Reference Image above.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("選択した参照画像がそのまま1本目のショットの開始フレームになります（白背景などもそのまま映ります）。以降のショットは前の映像を引き継ぎます。見た目の一貫性を高めますが、同一人物を完全に保証する機能ではありません。映画的な開始画像には、上の Opening Reference Image を推奨します。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Character", selection: Binding(
                        get: { anchor.characterID ?? characters.first?.id },
                        set: { setCharacter($0) }
                    )) {
                        ForEach(characters) { character in
                            Text(character.name).tag(Optional(character.id))
                        }
                    }
                    .frame(maxWidth: 320)

                    if selectableAssets.isEmpty {
                        Text("This character has no reference image that can start a shot. Extract a Front or Face reference first.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Picker("Reference", selection: Binding(
                            get: { anchor.referenceAssetID ?? selectableAssets.first?.id },
                            set: { setAsset($0) }
                        )) {
                            ForEach(selectableAssets) { asset in
                                Text(asset.displayLabel).tag(Optional(asset.id))
                            }
                        }
                        .frame(maxWidth: 320)
                    }
                }
                Spacer()
                preview
            }

            if let issue {
                Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text("Generation is blocked until this is resolved or the anchor is turned off.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let previewURL, let image = NSImage(contentsOf: previewURL) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 76, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                .accessibilityLabel("Character Anchor reference preview")
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.12))
                .frame(width: 76, height: 96)
                .overlay(Image(systemName: "person.crop.rectangle").foregroundStyle(.secondary))
        }
    }

    // MARK: - Mutations

    private func setEnabled(_ enabled: Bool) {
        update { anchor in
            anchor.isEnabled = enabled
            // Enabling with nothing chosen picks a sensible reference rather
            // than leaving the user with an enabled-but-inert control.
            if enabled, anchor.characterID == nil, let first = characters.first {
                anchor.characterID = first.id
                if let asset = CharacterAnchor.preferredAsset(for: first) {
                    anchor.referenceAssetID = asset.id
                    anchor.referenceAssetType = asset.type.rawValue
                }
            }
        }
    }

    private func setCharacter(_ id: UUID?) {
        guard let id, let character = characters.first(where: { $0.id == id }) else { return }
        update { anchor in
            anchor.characterID = id
            let asset = CharacterAnchor.preferredAsset(for: character)
            anchor.referenceAssetID = asset?.id
            anchor.referenceAssetType = asset?.type.rawValue
        }
    }

    private func setAsset(_ id: UUID?) {
        guard let id, let asset = selectableAssets.first(where: { $0.id == id }) else { return }
        update { anchor in
            anchor.referenceAssetID = id
            anchor.referenceAssetType = asset.type.rawValue
        }
    }

    private func update(_ mutate: (inout CharacterAnchor) -> Void) {
        guard var stored = store.project(id: project.id) else { return }
        mutate(&stored.characterAnchor)
        store.save(stored)
        onChanged()
    }
}
