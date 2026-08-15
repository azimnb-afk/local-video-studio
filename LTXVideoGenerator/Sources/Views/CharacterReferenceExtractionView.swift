import AppKit
import SwiftUI

struct CharacterReferenceExtractionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(CharacterSheetAnalysisMode.userDefaultsKey)
    private var analysisModeRaw = CharacterSheetAnalysisMode.auto.rawValue

    let projectID: UUID
    let characterID: UUID
    let sourceAsset: CharacterReferenceAsset
    let generationActive: Bool
    let onSave: ([CharacterReferenceAsset]) -> Void

    @State private var sourceImage: NSImage?
    @State private var proposals: [CharacterSheetRegionProposal] = []
    @State private var selectedProposalID: UUID?
    @State private var isDetecting = false
    @State private var statusMessage = "Preparing project-owned Character Sheet…"
    @State private var analysisProvider: String?
    @State private var analysisModel: String?
    @State private var saveError: String?

    private let store = FilmProjectStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HSplitView {
                canvasPane.frame(minWidth: 520, idealWidth: 650)
                proposalPane.frame(minWidth: 430, idealWidth: 500)
            }
            footer
        }
        .padding(16)
        .frame(minWidth: 1080, minHeight: 760)
        .interactiveDismissDisabled()
        .task { await prepareAndDetectIfAvailable() }
        .alert("Reference Extraction", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Reference Extraction Review").font(.headline)
                Text("Auto Detect is best effort. Move or resize every crop before saving if needed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isDetecting { ProgressView().controlSize(.small) }
            Button("Detect Again") { Task { await detectRegions() } }
                .disabled(generationActive || isDetecting || sourceImage == nil)
            Menu("Add Reference Crop") {
                ForEach(CharacterReferenceAssetType.extractableTypes, id: \.rawValue) { type in
                    Button(type.referenceDisplayName) { addManualRegion(type: type) }
                }
            }
            .disabled(sourceImage == nil)
        }
    }

    private var canvasPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let sourceImage {
                CharacterSheetCropCanvas(
                    image: sourceImage,
                    proposals: $proposals,
                    selectedProposalID: $selectedProposalID
                )
                .background(Color.black.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                ContentUnavailableView("Character Sheet Unavailable", systemImage: "photo")
            }
            Text(statusMessage)
                .font(.caption)
                .foregroundStyle(statusMessage.contains("unavailable") ? .orange : .secondary)
            Text("Coordinates: normalized 0…1 · top-left origin · final PNG crops use the ORIGINAL image")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var proposalPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Detected References").font(.headline)
                Spacer()
                Text("\(proposals.filter(\.isSelected).count) selected")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if proposals.isEmpty && !isDetecting {
                ContentUnavailableView(
                    "Add a Reference Crop",
                    systemImage: "crop",
                    description: Text("Manual extraction works without Local Vision.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach($proposals) { $proposal in
                            CharacterSheetProposalRow(
                                sourceImage: sourceImage,
                                proposal: $proposal,
                                isActive: selectedProposalID == proposal.id,
                                onSelect: { selectedProposalID = proposal.id },
                                onDelete: {
                                    proposals.removeAll { $0.id == proposal.id }
                                    if selectedProposalID == proposal.id { selectedProposalID = proposals.first?.id }
                                }
                            )
                        }
                    }
                }
            }
        }
        .padding(.leading, 10)
    }

    private var footer: some View {
        HStack {
            Label(
                "Reference images are saved locally. When selected as a Character Anchor, a reference can be used as the opening shot's starting image. It does not guarantee identity.",
                systemImage: "lock.shield"
            )
            .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { dismiss() }
            Button("Save Reference Images") { saveReferences() }
                .buttonStyle(.borderedProminent)
                .disabled(sourceImage == nil || proposals.allSatisfy { !$0.isSelected })
        }
    }

    @MainActor
    private func prepareAndDetectIfAvailable() async {
        guard let url = sourceURL else {
            statusMessage = "The project-owned source Character Sheet is unavailable. Existing derived references remain valid."
            return
        }
        sourceImage = NSImage(contentsOf: url)
        guard sourceImage != nil else {
            statusMessage = "The project-owned source Character Sheet is unavailable."
            return
        }
        await detectRegions()
    }

    @MainActor
    private func detectRegions() async {
        guard !generationActive else {
            statusMessage = CharacterSheetAnalysisError.generationInProgress.localizedDescription
            return
        }
        guard let sourceURL else { return }
        isDetecting = true
        statusMessage = "Detecting reference regions with Local Vision…"
        defer { isDetecting = false }

        let requestedMode = CharacterSheetAnalysisMode(rawValue: analysisModeRaw) ?? .auto
        let snapshot = await CharacterSheetVisionEnvironmentService().refresh(mode: requestedMode)
        guard snapshot.effectiveMode == .localVision, let model = snapshot.effectiveModel else {
            statusMessage = "Local Vision unavailable. Add and adjust reference crops manually."
            return
        }
        do {
            let analysisData = try CharacterSheetImagePreprocessor.analysisData(from: sourceURL)
            let original = try CharacterReferenceExtractionService.orientedOriginalImage(from: sourceURL)
            let analyzer = CharacterSheetRegionAnalyzer(
                provider: OllamaCharacterSheetVisionProvider(model: model),
                generationIsActive: { generationActive }
            )
            let detected = try await analyzer.analyze(
                imageData: analysisData,
                imageWidth: original.width,
                imageHeight: original.height
            )
            proposals = detected
            selectedProposalID = detected.first?.id
            analysisProvider = "ollama"
            analysisModel = model
            statusMessage = "Auto Detect · Best Effort · \(detected.count) proposal(s) · \(model)"
        } catch {
            statusMessage = "Auto Detect unavailable: \(error.localizedDescription) Add crops manually."
        }
    }

    private func addManualRegion(type: CharacterReferenceAssetType) {
        let count = proposals.filter { $0.type == type }.count + 1
        let proposal = CharacterSheetRegionProposal(
            type: type,
            label: count == 1 ? type.referenceDisplayName : "\(type.referenceDisplayName) \(count)",
            normalizedRect: NormalizedCropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
            origin: .manual,
            isUserAdjusted: true
        )
        proposals.append(proposal)
        selectedProposalID = proposal.id
    }

    private func saveReferences() {
        guard let sourceURL else { return }
        do {
            let assets = try CharacterReferenceExtractionService().extract(
                proposals: proposals,
                sourceAsset: sourceAsset,
                sourceURL: sourceURL,
                projectID: projectID,
                characterID: characterID,
                analysisProvider: analysisProvider,
                analysisModel: analysisModel
            )
            onSave(assets)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private var sourceURL: URL? {
        guard let relativePath = sourceAsset.projectRelativePath else { return nil }
        return store.managedCharacterAssetURL(projectID: projectID, relativePath: relativePath)
    }
}

// MARK: - Editable overlay canvas

private struct CharacterSheetCropCanvas: View {
    let image: NSImage
    @Binding var proposals: [CharacterSheetRegionProposal]
    @Binding var selectedProposalID: UUID?

    var body: some View {
        GeometryReader { geometry in
            let fitted = fittedImageRect(in: geometry.size)
            ZStack(alignment: .topLeading) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: fitted.width, height: fitted.height)
                    .offset(x: fitted.minX, y: fitted.minY)
                ForEach($proposals) { $proposal in
                    if proposal.isSelected {
                        AdjustableCropOverlay(
                            proposal: $proposal,
                            canvasSize: fitted.size,
                            isActive: selectedProposalID == proposal.id,
                            onSelect: { selectedProposalID = proposal.id }
                        )
                        .frame(width: fitted.width, height: fitted.height)
                        .offset(x: fitted.minX, y: fitted.minY)
                    }
                }
            }
        }
        .aspectRatio(max(0.2, image.size.width / max(image.size.height, 1)), contentMode: .fit)
        .padding(6)
    }

    private func fittedImageRect(in available: CGSize) -> CGRect {
        let imageAspect = image.size.width / max(image.size.height, 1)
        let availableAspect = available.width / max(available.height, 1)
        if availableAspect > imageAspect {
            let width = available.height * imageAspect
            return CGRect(x: (available.width - width) / 2, y: 0, width: width, height: available.height)
        }
        let height = available.width / imageAspect
        return CGRect(x: 0, y: (available.height - height) / 2, width: available.width, height: height)
    }
}

private struct AdjustableCropOverlay: View {
    @Binding var proposal: CharacterSheetRegionProposal
    let canvasSize: CGSize
    let isActive: Bool
    let onSelect: () -> Void

    @State private var moveStart: NormalizedCropRect?
    @State private var resizeStart: NormalizedCropRect?

    var body: some View {
        let frame = CGRect(
            x: proposal.normalizedRect.x * canvasSize.width,
            y: proposal.normalizedRect.y * canvasSize.height,
            width: proposal.normalizedRect.width * canvasSize.width,
            height: proposal.normalizedRect.height * canvasSize.height
        )
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill((isActive ? Color.accentColor : .yellow).opacity(0.08))
                .overlay(Rectangle().stroke(isActive ? Color.accentColor : .yellow, lineWidth: isActive ? 3 : 2))
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
                .contentShape(Rectangle())
                .onTapGesture(perform: onSelect)
                .gesture(moveGesture)
            Text(proposal.label)
                .font(.caption2.bold())
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background((isActive ? Color.accentColor : .yellow).opacity(0.9))
                .foregroundStyle(.black)
                .lineLimit(1)
                .offset(x: frame.minX, y: max(0, frame.minY - 18))
            Circle()
                .fill(isActive ? Color.accentColor : .yellow)
                .frame(width: 14, height: 14)
                .offset(x: frame.maxX - 7, y: frame.maxY - 7)
                .gesture(resizeGesture)
                .help("Drag to resize crop")
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                onSelect()
                if moveStart == nil { moveStart = proposal.normalizedRect }
                guard let start = moveStart else { return }
                let dx = value.translation.width / max(canvasSize.width, 1)
                let dy = value.translation.height / max(canvasSize.height, 1)
                proposal.normalizedRect.x = min(max(0, start.x + dx), 1 - start.width)
                proposal.normalizedRect.y = min(max(0, start.y + dy), 1 - start.height)
                proposal.isUserAdjusted = true
            }
            .onEnded { _ in moveStart = nil }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                onSelect()
                if resizeStart == nil { resizeStart = proposal.normalizedRect }
                guard let start = resizeStart else { return }
                let dw = value.translation.width / max(canvasSize.width, 1)
                let dh = value.translation.height / max(canvasSize.height, 1)
                proposal.normalizedRect.width = min(max(0.02, start.width + dw), 1 - start.x)
                proposal.normalizedRect.height = min(max(0.02, start.height + dh), 1 - start.y)
                proposal.isUserAdjusted = true
            }
            .onEnded { _ in resizeStart = nil }
    }
}

// MARK: - Proposal list

private struct CharacterSheetProposalRow: View {
    let sourceImage: NSImage?
    @Binding var proposal: CharacterSheetRegionProposal
    let isActive: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Toggle("", isOn: $proposal.isSelected).labelsHidden()
            preview
                .frame(width: 78, height: 78)
                .background(Color.black.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 5) {
                Picker("Reference Type", selection: typeBinding) {
                    ForEach(CharacterReferenceAssetType.extractableTypes, id: \.rawValue) { type in
                        Text(type.referenceDisplayName).tag(type)
                    }
                }
                .labelsHidden()
                TextField("Label", text: labelBinding)
                Text(normalizedDescription)
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    coordinateField("X", keyPath: \.x)
                    coordinateField("Y", keyPath: \.y)
                    coordinateField("W", keyPath: \.width)
                    coordinateField("H", keyPath: \.height)
                }
                Text(proposal.origin == .manual
                     ? "Manual crop"
                     : proposal.isUserAdjusted ? "Auto proposal · adjusted" : "Auto proposal · review required")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(
            isActive ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor)
        ))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    @ViewBuilder private var preview: some View {
        if let sourceImage, let cropped = cropPreview(sourceImage, rect: proposal.normalizedRect) {
            Image(nsImage: cropped).resizable().scaledToFit()
        } else {
            Image(systemName: "crop").foregroundStyle(.secondary)
        }
    }

    private var typeBinding: Binding<CharacterReferenceAssetType> {
        Binding(
            get: { proposal.type },
            set: { proposal.type = $0; proposal.isUserAdjusted = true }
        )
    }

    private var labelBinding: Binding<String> {
        Binding(
            get: { proposal.label },
            set: { proposal.label = $0; proposal.isUserAdjusted = true }
        )
    }

    private var normalizedDescription: String {
        let rect = proposal.normalizedRect
        return String(format: "x %.3f  y %.3f  w %.3f  h %.3f", rect.x, rect.y, rect.width, rect.height)
    }

    private func coordinateField(
        _ label: String,
        keyPath: WritableKeyPath<NormalizedCropRect, Double>
    ) -> some View {
        TextField(label, value: Binding(
            get: { proposal.normalizedRect[keyPath: keyPath] },
            set: { newValue in
                var candidate = proposal.normalizedRect
                candidate[keyPath: keyPath] = newValue
                if keyPath == \.x {
                    candidate.x = min(max(0, candidate.x), 1 - candidate.width)
                } else if keyPath == \.y {
                    candidate.y = min(max(0, candidate.y), 1 - candidate.height)
                } else if keyPath == \.width {
                    candidate.width = min(max(0.02, candidate.width), 1 - candidate.x)
                } else {
                    candidate.height = min(max(0.02, candidate.height), 1 - candidate.y)
                }
                proposal.normalizedRect = candidate
                proposal.isUserAdjusted = true
            }
        ), format: .number.precision(.fractionLength(3)))
        .textFieldStyle(.roundedBorder)
        .frame(width: 62)
        .accessibilityLabel("\(label) normalized coordinate")
    }

    private func cropPreview(_ image: NSImage, rect: NormalizedCropRect) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let pixelRect = try? CharacterReferenceExtractionService.pixelRect(
                for: rect, imageWidth: cgImage.width, imageHeight: cgImage.height
              ),
              let cropped = cgImage.cropping(to: pixelRect) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
    }
}

// MARK: - Saved reference thumbnails

struct ManagedCharacterReferenceThumbnail: View {
    let projectID: UUID
    let asset: CharacterReferenceAsset
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: asset.type == .characterSheet ? "photo.on.rectangle" : "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: asset.projectRelativePath) {
            guard let path = asset.projectRelativePath,
                  let url = FilmProjectStore.shared.managedCharacterAssetURL(
                    projectID: projectID, relativePath: path
                  ) else { return }
            image = await Task.detached {
                CharacterReferenceThumbnailLoader.image(from: url)
            }.value
        }
    }
}
