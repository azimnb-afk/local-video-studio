import Foundation

/// Specific reason why the re-anchor engine reached its decision for a shot.
enum ReanchorReason: String, Codable, Sendable, Equatable {
    case disabled = "disabled"
    case noAnchor = "noAnchor"
    case explicitShotSource = "explicitShotSource"
    case identityRefreshAsset = "identityRefreshAsset"
    case naturalCut = "naturalCut"
    case manualRequest = "manualRequest"
    case chainWithinLimit = "chainWithinLimit"
    case longContinueChain = "longContinueChain"
    case unsupportedBackend = "unsupportedBackend"
}

/// The chosen conditioning strategy for the shot.
enum ConditioningStrategy: String, Codable, Sendable, Equatable {
    case none = "none"
    case explicitSource = "explicitSource"
    case identityAnchor = "identityAnchor"
    case previousFinalFrame = "previousFinalFrame"
    case identityRefresh = "identityRefresh"
}

/// Back-end capability and experimental validation status for natural-CUT Identity Re-anchor.
enum IdentityReanchorBackendValidation: String, Codable, Sendable, Equatable {
    case supportedAndValidated = "supportedAndValidated"
    case supportedUnvalidated = "supportedUnvalidated"
    case unsupported = "unsupported"

    static func status(for modelID: String?) -> Self {
        guard let modelID = modelID?.trimmingCharacters(in: .whitespacesAndNewlines), !modelID.isEmpty else {
            return .supportedUnvalidated
        }
        if modelID == MiniMaxH3Configuration.modelID || modelID == LTXModelCatalog.defaultModelID {
            return .supportedAndValidated
        }
        return .supportedUnvalidated
    }
}

/// Deterministic result of evaluating a shot's re-anchoring needs.
struct IdentityReanchorDecision: Codable, Sendable, Equatable {
    let shouldApplyAnchor: Bool
    let shouldRecommendReanchor: Bool
    let reason: ReanchorReason
    let conditioningStrategy: ConditioningStrategy
    let resultingContinueChainIndex: Int
    let reanchorApplied: Bool

    init(
        shouldApplyAnchor: Bool,
        shouldRecommendReanchor: Bool,
        reason: ReanchorReason,
        conditioningStrategy: ConditioningStrategy,
        resultingContinueChainIndex: Int,
        reanchorApplied: Bool
    ) {
        self.shouldApplyAnchor = shouldApplyAnchor
        self.shouldRecommendReanchor = shouldRecommendReanchor
        self.reason = reason
        self.conditioningStrategy = conditioningStrategy
        self.resultingContinueChainIndex = resultingContinueChainIndex
        self.reanchorApplied = reanchorApplied
    }
}

/// Deterministic decision engine for Project Identity Keyframe / Re-anchor.
///
/// Principles:
/// - Never rewrite transition intent (CONTINUE is never silently mutated into CUT).
/// - Natural CUT boundaries are the primary anchor points.
/// - Explicit shot sources outrank automatic re-anchoring.
/// - When CONTINUE chains exceed `maxContinueChainLength`, mark `reanchorRecommended = true`
///   without destroying temporal continuity.
enum IdentityReanchorEngine {

    static func decide(
        reanchorPolicy: IdentityReanchorPolicy,
        identityAnchor: ProjectIdentityAnchor?,
        shotIndex: Int,
        transitionIntent: ShotContinuityMode,
        previousContinueChainIndex: Int,
        maxContinueChainLength: Int = 3,
        hasExplicitShotSource: Bool,
        hasIdentityRefreshAsset: Bool
    ) -> IdentityReanchorDecision {
        // Priority 1: Explicit user-specified source image always wins.
        if hasExplicitShotSource {
            let chainIndex = (transitionIntent == .continueFromPrevious && shotIndex > 0)
                ? previousContinueChainIndex + 1 : 0
            return IdentityReanchorDecision(
                shouldApplyAnchor: false,
                shouldRecommendReanchor: false,
                reason: .explicitShotSource,
                conditioningStrategy: .explicitSource,
                resultingContinueChainIndex: chainIndex,
                reanchorApplied: false
            )
        }

        // Priority 2: Operational IdentityRefresh frame asset.
        if hasIdentityRefreshAsset {
            return IdentityReanchorDecision(
                shouldApplyAnchor: false,
                shouldRecommendReanchor: false,
                reason: .identityRefreshAsset,
                conditioningStrategy: .identityRefresh,
                resultingContinueChainIndex: 0,
                reanchorApplied: false
            )
        }

        // Priority 3: Policy OFF or No Identity Anchor available.
        guard reanchorPolicy != .off else {
            let isContinue = (transitionIntent == .continueFromPrevious && shotIndex > 0)
            return IdentityReanchorDecision(
                shouldApplyAnchor: false,
                shouldRecommendReanchor: false,
                reason: .disabled,
                conditioningStrategy: isContinue ? .previousFinalFrame : .none,
                resultingContinueChainIndex: isContinue ? previousContinueChainIndex + 1 : 0,
                reanchorApplied: false
            )
        }

        guard identityAnchor != nil else {
            let isContinue = (transitionIntent == .continueFromPrevious && shotIndex > 0)
            return IdentityReanchorDecision(
                shouldApplyAnchor: false,
                shouldRecommendReanchor: false,
                reason: .noAnchor,
                conditioningStrategy: isContinue ? .previousFinalFrame : .none,
                resultingContinueChainIndex: isContinue ? previousContinueChainIndex + 1 : 0,
                reanchorApplied: false
            )
        }

        // Priority 4: Policy Automatic with available Identity Anchor.
        if reanchorPolicy == .automatic {
            // Case A: Natural CUT boundary (Shot 0 or explicit CUT)
            if shotIndex == 0 || transitionIntent == .cut {
                return IdentityReanchorDecision(
                    shouldApplyAnchor: true,
                    shouldRecommendReanchor: false,
                    reason: .naturalCut,
                    conditioningStrategy: .identityAnchor,
                    resultingContinueChainIndex: 0,
                    reanchorApplied: true
                )
            }

            // Case B: CONTINUE transition
            let newChainIndex = previousContinueChainIndex + 1
            let isLongChain = newChainIndex > maxContinueChainLength
            return IdentityReanchorDecision(
                shouldApplyAnchor: false,
                shouldRecommendReanchor: isLongChain,
                reason: isLongChain ? .longContinueChain : .chainWithinLimit,
                conditioningStrategy: .previousFinalFrame,
                resultingContinueChainIndex: newChainIndex,
                reanchorApplied: false
            )
        }

        // Priority 5: Policy Manual
        let isContinue = (transitionIntent == .continueFromPrevious && shotIndex > 0)
        return IdentityReanchorDecision(
            shouldApplyAnchor: false,
            shouldRecommendReanchor: false,
            reason: .chainWithinLimit,
            conditioningStrategy: isContinue ? .previousFinalFrame : .none,
            resultingContinueChainIndex: isContinue ? previousContinueChainIndex + 1 : 0,
            reanchorApplied: false
        )
    }
}
