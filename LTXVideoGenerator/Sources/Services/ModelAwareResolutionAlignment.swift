import Foundation

/// Dimensions of a video canvas in pixels.
public struct VideoDimensions: Equatable, Codable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// Pixel insets for deterministic cropping.
public struct PixelInsets: Equatable, Codable, Sendable {
    public var top: Int
    public var bottom: Int
    public var left: Int
    public var right: Int

    public init(top: Int = 0, bottom: Int = 0, left: Int = 0, right: Int = 0) {
        self.top = top
        self.bottom = bottom
        self.left = left
        self.right = right
    }

    public var hasCrop: Bool {
        top > 0 || bottom > 0 || left > 0 || right > 0
    }

    public var totalVerticalCrop: Int { top + bottom }
    public var totalHorizontalCrop: Int { left + right }
}

/// Reason explaining the resolution alignment decision.
public enum AlignmentReason: String, Equatable, Codable, Sendable {
    case alreadyCompatible
    case modelGridAlignment
    case validatedPreset
    case unsupported
}

/// Result of model-aware resolution alignment.
public struct ResolutionAlignmentResult: Equatable, Codable, Sendable {
    public let requested: VideoDimensions
    public let generation: VideoDimensions
    public let finalOutput: VideoDimensions
    public let crop: PixelInsets?
    public let alignmentMultiple: Int?
    public let alignmentReason: AlignmentReason

    public init(
        requested: VideoDimensions,
        generation: VideoDimensions,
        finalOutput: VideoDimensions,
        crop: PixelInsets?,
        alignmentMultiple: Int?,
        alignmentReason: AlignmentReason
    ) {
        self.requested = requested
        self.generation = generation
        self.finalOutput = finalOutput
        self.crop = crop
        self.alignmentMultiple = alignmentMultiple
        self.alignmentReason = alignmentReason
    }
}

/// Deterministic policy for model-aware resolution alignment.
///
/// Disentangles three core dimensions:
/// 1. Requested Resolution: What the user/project asked for.
/// 2. Generation Resolution: Dimensions sent to the backend/model (aligned to grid).
/// 3. Final Output Resolution: Dimensions restored/cropped to match user intent.
public enum ModelAwareResolutionAlignment {

    /// Retrieves the proven alignment multiple for a given backend kind.
    static func alignmentMultiple(for backend: GenerationBackendKind) -> Int? {
        switch backend {
        case .mlxVideoWithAudio:
            return 64
        case .ltx2MLX:
            return 32
        case .minimaxH3:
            return nil
        }
    }

    /// Retrieves the alignment multiple for a given model ID.
    /// Returns nil (NO-OP) for unknown, nil, empty, or unsupported models.
    public static func alignmentMultiple(for modelID: String?) -> Int? {
        guard let modelID = modelID?.trimmingCharacters(in: .whitespacesAndNewlines), !modelID.isEmpty else {
            return nil
        }
        if MiniMaxH3Configuration.isMiniMaxH3(modelID: modelID) { return nil }
        let resolved = GenerationModelResolver.resolve(modelID: modelID)
        switch resolved {
        case .runnable(let runnable):
            return alignmentMultiple(for: runnable.backend)
        case .unsupported:
            return nil
        }
    }

    /// Aligns requested dimensions to model-compatible boundaries deterministically.
    public static func align(
        requestedWidth: Int,
        requestedHeight: Int,
        modelID: String?,
        isContinuation: Bool = false,
        workflowMode: String? = nil
    ) -> ResolutionAlignmentResult {
        let requested = VideoDimensions(width: requestedWidth, height: requestedHeight)

        // MiniMax H3 uses validated resolution presets/tiers; do not modify.
        if MiniMaxH3Configuration.isMiniMaxH3(modelID: modelID) {
            return ResolutionAlignmentResult(
                requested: requested,
                generation: requested,
                finalOutput: requested,
                crop: nil,
                alignmentMultiple: nil,
                alignmentReason: .validatedPreset
            )
        }

        guard let multiple = alignmentMultiple(for: modelID), multiple > 0 else {
            let reason: AlignmentReason
            if modelID == nil || (modelID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                reason = .unsupported
            } else {
                let resolved = GenerationModelResolver.resolve(modelID: modelID!)
                switch resolved {
                case .runnable:
                    reason = .alreadyCompatible
                case .unsupported:
                    reason = .unsupported
                }
            }
            return ResolutionAlignmentResult(
                requested: requested,
                generation: requested,
                finalOutput: requested,
                crop: nil,
                alignmentMultiple: nil,
                alignmentReason: reason
            )
        }

        guard requestedWidth > 0, requestedHeight > 0 else {
            return ResolutionAlignmentResult(
                requested: requested,
                generation: requested,
                finalOutput: requested,
                crop: nil,
                alignmentMultiple: multiple,
                alignmentReason: .unsupported
            )
        }

        let widthMod = requestedWidth % multiple
        let heightMod = requestedHeight % multiple

        if widthMod == 0 && heightMod == 0 {
            return ResolutionAlignmentResult(
                requested: requested,
                generation: requested,
                finalOutput: requested,
                crop: nil,
                alignmentMultiple: multiple,
                alignmentReason: .alreadyCompatible
            )
        }

        // Expansion: expand to nearest grid multiple (ceil)
        let genWidth: Int
        if widthMod == 0 {
            genWidth = requestedWidth
        } else {
            genWidth = ((requestedWidth + multiple - 1) / multiple) * multiple
        }

        let genHeight: Int
        if heightMod == 0 {
            genHeight = requestedHeight
        } else {
            genHeight = ((requestedHeight + multiple - 1) / multiple) * multiple
        }

        let deltaW = genWidth - requestedWidth
        let deltaH = genHeight - requestedHeight

        // Deterministic symmetric centered crop distribution
        let cropLeft = deltaW / 2
        let cropRight = deltaW - cropLeft
        let cropTop = deltaH / 2
        let cropBottom = deltaH - cropTop

        let insets = PixelInsets(top: cropTop, bottom: cropBottom, left: cropLeft, right: cropRight)

        return ResolutionAlignmentResult(
            requested: requested,
            generation: VideoDimensions(width: genWidth, height: genHeight),
            finalOutput: requested,
            crop: insets.hasCrop ? insets : nil,
            alignmentMultiple: multiple,
            alignmentReason: .modelGridAlignment
        )
    }
}
