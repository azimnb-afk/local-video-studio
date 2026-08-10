import SwiftUI

/// Choose / Replace / Clear for an opening reference image, over a plain file
/// URL rather than a project.
///
/// Used by the New Auto Movie sheet, where no FilmProject exists yet: nothing is
/// copied into a project until Create is pressed, so cancelling the sheet leaves
/// no managed asset behind. `OpeningReferenceSection` uses the same controls
/// once a project exists, against its already-imported copy.
struct OpeningReferencePicker: View {
    @Binding var selection: URL?
    var compact: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button(selection == nil ? "Choose Image…" : "Replace…") { choose() }
                    if selection != nil {
                        Button("Clear", role: .destructive) { selection = nil }
                    }
                }
                if let selection {
                    Text(selection.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 240, alignment: .leading)
                }
            }
            Spacer()
            preview
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let selection, let image = NSImage(contentsOf: selection) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: compact ? 104 : 128, height: compact ? 70 : 86)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                .accessibilityLabel("Opening reference image preview")
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.12))
                .frame(width: compact ? 104 : 128, height: compact ? 70 : 86)
                .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Use Image"
        if panel.runModal() == .OK { selection = panel.url }
    }
}

/// The shared explanation, so the sheet and the project page cannot drift apart
/// on what this control actually does.
struct OpeningReferenceExplanation: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Used as the visual starting point for the first shot only. Later shots continue from the previous shot. For best results use an image that already contains the intended character, clothing, and scene — character sheets and plain reference plates appear directly in the opening frame.")
            Text("1本目のショットの開始画像としてのみ使用します。以降のショットは前の映像を引き継ぎます。人物・服装・背景がシーンとして成立している画像を推奨します（キャラクターシートや白背景の画像はそのまま開始フレームに映ります）。")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}
