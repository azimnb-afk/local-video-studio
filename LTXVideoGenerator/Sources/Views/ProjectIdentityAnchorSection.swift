import SwiftUI
import AppKit

/// Project-level UI for managing the immutable Character Identity Keyframe (Phase 1).
///
/// Plain-language beginner interface:
/// - "キャラクター外観を維持" (Maintain Character Appearance) [On / Off]
/// - "参照画像" (Reference Image) [画像を選択 / 変更 / 削除]
/// - Technical low-level concepts (latents, VAE, patch grids, chain indexes) are completely hidden.
struct ProjectIdentityAnchorSection: View {
    let project: FilmProject
    let onChanged: () -> Void

    private let store = FilmProjectStore.shared
    private let anchorService = PreparedIdentityAnchorService.shared

    @State private var isSelectingFile = false
    @State private var errorMessage: String?

    private var isPolicyActive: Bool {
        project.reanchorPolicy != .off
    }

    private var anchor: ProjectIdentityAnchor? {
        project.identityAnchor
    }

    private var anchorImageURL: URL? {
        guard let anchor = project.identityAnchor else { return nil }
        return store.managedProjectAssetURL(projectID: project.id, relativePath: anchor.projectRelativePath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("キャラクター外観を維持")
                        .font(.headline)
                    Text("Maintain Character Appearance")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { isPolicyActive },
                    set: { toggleEnabled($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }

            if isPolicyActive {
                VStack(alignment: .leading, spacing: 8) {
                    if let imageURL = anchorImageURL, let nsImage = NSImage(contentsOf: imageURL) {
                        HStack(spacing: 12) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 96, height: 96)
                                .cornerRadius(6)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 1))

                            VStack(alignment: .leading, spacing: 4) {
                                Text("登録済み参照画像")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                if let w = anchor?.originalWidth, let h = anchor?.originalHeight {
                                    Text("\(w) × \(h) px")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                HStack(spacing: 8) {
                                    Button("変更...") {
                                        selectAndImportImage()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)

                                    Button("削除", role: .destructive) {
                                        removeAnchor()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                                .padding(.top, 4)
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text("参照画像が未設定です。基準となる画像を選択してください。")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            Button("画像を選択...") {
                                selectAndImportImage()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                }
                .padding(.top, 4)
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text("自然なカットで参照画像を再適用することで、キャラクターの外観を維持しやすくし、その後の連続ショットにも引き継ぎます。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    private func toggleEnabled(_ enable: Bool) {
        guard var updated = store.project(id: project.id) else { return }
        if enable {
            updated.reanchorPolicy = .automatic
            if updated.identityAnchor == nil {
                selectAndImportImage()
                return
            }
        } else {
            updated.reanchorPolicy = .off
        }
        store.save(updated)
        onChanged()
    }

    private func selectAndImportImage() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.png, .jpeg, .webP]
        panel.prompt = "参照画像として設定"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                guard var updated = store.project(id: project.id) else { return }
                if let oldAnchor = updated.identityAnchor {
                    anchorService.removeAnchor(anchor: oldAnchor, projectID: project.id, store: store)
                }
                let imported = try anchorService.importAnchor(
                    sourceURL: url,
                    projectID: project.id,
                    store: store
                )
                updated.identityAnchor = imported
                updated.reanchorPolicy = .automatic
                store.save(updated)
                errorMessage = nil
                onChanged()
            } catch {
                errorMessage = "画像の読み込みに失敗しました: \(error.localizedDescription)"
            }
        }
    }

    private func removeAnchor() {
        guard var updated = store.project(id: project.id), let anchor = updated.identityAnchor else { return }
        anchorService.removeAnchor(anchor: anchor, projectID: project.id, store: store)
        updated.identityAnchor = nil
        updated.reanchorPolicy = .off
        store.save(updated)
        errorMessage = nil
        onChanged()
    }
}
