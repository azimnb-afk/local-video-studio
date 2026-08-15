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

    @State private var extractingSheetAsset: CharacterReferenceAsset?
    @State private var assetOperationError: String?

    private var anchor: CharacterAnchor { project.characterAnchor }

    private var characters: [BibleCharacter] {
        project.characterBible.characters
    }

    private var selectedCharacter: BibleCharacter? {
        guard let id = anchor.characterID else { return nil }
        return characters.first { $0.id == id }
    }

    private var selectedCharacterSheetAsset: CharacterReferenceAsset? {
        selectedCharacter?.referenceAssets.first { $0.type == .characterSheet }
    }

    /// Character sheets are excluded: a multi-pose layout is not a frame a shot
    /// can begin on.
    private var selectableAssets: [CharacterReferenceAsset] {
        (selectedCharacter?.referenceAssets ?? []).filter { $0.isStartingImageCandidate }
    }

    private var hasOpeningReference: Bool {
        project.openingReferenceImage != nil
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

            if hasOpeningReference && anchor.isEnabled {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                    Text("Opening Reference Image is active, so Character Anchor will not be used for Shot 1.")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
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
        .sheet(item: $extractingSheetAsset) { sourceAsset in
            if let character = selectedCharacter {
                CharacterReferenceExtractionSheet(
                    projectID: project.id,
                    characterID: character.id,
                    sourceAsset: sourceAsset,
                    generationActive: false
                ) { assets in
                    saveExtractedAssets(assets, for: character.id)
                    extractingSheetAsset = nil
                }
            }
        }
        .alert("Reference Images", isPresented: Binding(
            get: { assetOperationError != nil },
            set: { if !$0 { assetOperationError = nil } }
        )) {
            Button("OK", role: .cancel) { assetOperationError = nil }
        } message: {
            Text(assetOperationError ?? "")
        }
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
                        if let sheetAsset = selectedCharacterSheetAsset {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("No starting reference image is available for this character.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                Button("Extract References…") {
                                    extractingSheetAsset = sheetAsset
                                }
                                .controlSize(.small)
                                Text("Front is recommended for most openings; Face provides stronger facial detail but may favor a close-up.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("No starting reference image is available. Add a Character Sheet in Character Bible, then extract reference images.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Picker("Reference", selection: Binding(
                                get: { anchor.referenceAssetID ?? selectableAssets.first?.id },
                                set: { setAsset($0) }
                            )) {
                                ForEach(selectableAssets) { asset in
                                    Text(asset.displayLabel).tag(Optional(asset.id))
                                }
                            }
                            .frame(maxWidth: 320)

                            Text("Front is recommended for most openings; Face provides stronger facial detail but may favor a close-up.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
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

    private func saveExtractedAssets(_ assets: [CharacterReferenceAsset], for characterID: UUID) {
        guard var updated = store.project(id: project.id),
              var character = updated.characterBible.character(id: characterID) else { return }
        let updatedAssets = character.referenceAssets + assets
        character.referenceAssets = updatedAssets
        character.updatedAt = Date()
        updated.upsertCharacter(character)

        // If no referenceAssetID is set or the current one is not among valid candidates, select preferredAsset
        if updated.characterAnchor.referenceAssetID == nil ||
           !updatedAssets.contains(where: { $0.id == updated.characterAnchor.referenceAssetID && $0.isStartingImageCandidate }) {
            if let preferred = CharacterAnchor.preferredAsset(for: character) {
                updated.characterAnchor.referenceAssetID = preferred.id
                updated.characterAnchor.referenceAssetType = preferred.type.rawValue
            }
        }

        do {
            try store.saveThrowing(updated)
            onChanged()
        } catch {
            for asset in assets {
                store.removeManagedCharacterAsset(projectID: project.id, asset: asset)
            }
            assetOperationError = "Reference images were not saved: \(error.localizedDescription)"
        }
    }

    private func update(_ mutate: (inout CharacterAnchor) -> Void) {
        guard var stored = store.project(id: project.id) else { return }
        mutate(&stored.characterAnchor)
        store.save(stored)
        onChanged()
    }
}
