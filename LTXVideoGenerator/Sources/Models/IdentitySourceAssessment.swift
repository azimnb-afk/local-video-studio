import Foundation

/// What a continuity frame actually *shows*, in visibility terms only.
///
/// This is not face recognition and makes no claim about who the person is. It
/// answers one question: does this frame carry enough visual information for the
/// next shot to work from? A frame showing the subject from behind at the far
/// end of a courtyard is a perfectly good continuity frame for another wide
/// shot and a useless one for a close-up.
struct IdentitySourceAssessment: Codable, Equatable {

    enum Status: String, Codable {
        case assessed
        /// Local Vision was not reachable or no vision model is configured.
        case unavailable
        /// The model answered with nothing usable.
        case failed
    }

    enum SubjectScale: String, Codable {
        case tiny, small, medium, large, unknown
    }

    enum Visibility: String, Codable {
        case clear, partial, none, unknown
    }

    enum Orientation: String, Codable {
        case front, threeQuarter, profile, back, ambiguous
    }

    var status: Status = .unavailable
    var sourceRelativePath: String = ""
    var subjectPresent: Bool = false
    var subjectCount: Int = 0
    var subjectScale: SubjectScale = .unknown
    var faceVisibility: Visibility = .unknown
    var hairVisibility: Visibility = .unknown
    var costumeVisibility: Visibility = .unknown
    var subjectOrientation: Orientation = .ambiguous
    var analysisModel: String = ""
    var assessedAt: Date?
    var ambiguityReason: String = ""

    var isAssessed: Bool { status == .assessed }
}

// MARK: - What the next shot needs

/// Whether the next shot depends on facial detail the source may not have.
///
/// Derived from the shot's own camera plan rather than from a model: the
/// Director already records a shot scale, and a close framing is exactly the
/// case where an absent face has to be invented.
enum IdentityDetailRequirement: String, Equatable {
    /// Close framing — the face will fill enough of the frame to matter.
    case faceCritical
    /// Mid framing — identity is visible but not dominant.
    case moderate
    /// Wide framing — the subject is small; identity detail is not load-bearing.
    case low

    /// Shot scales are free text from the Director, so matching is tolerant.
    static func from(shotScale: String?) -> IdentityDetailRequirement {
        let scale = (shotScale ?? "").lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        guard !scale.isEmpty else { return .moderate }
        // Order matters: "medium-close-up" must not be read as "medium", and
        // "extreme-wide" must not be read as "wide" being close.
        if scale.contains("extreme-close") || scale.contains("extreme-closeup") { return .faceCritical }
        if scale.contains("close") { return .faceCritical }
        if scale.contains("wide") || scale.contains("establishing") || scale.contains("long") {
            return .low
        }
        if scale.contains("medium") || scale.contains("mid") { return .moderate }
        return .moderate
    }
}

/// Every threshold in one place, named for what it means rather than what it
/// equals, so tests describe behaviour instead of integers.
enum IdentityRefreshThresholds {
    /// Framings whose face detail the source must actually supply.
    static let requirementsNeedingFace: Set<IdentityDetailRequirement> = [.faceCritical]
    /// Subject scales too small to carry usable facial detail forward.
    static let riskySubjectScales: Set<IdentitySourceAssessment.SubjectScale> = [.tiny, .small]
    /// Orientations from which no face can be inherited.
    static let riskyOrientations: Set<IdentitySourceAssessment.Orientation> = [.back]
    /// Face visibility that cannot support a closer shot.
    static let riskyFaceVisibility: Set<IdentitySourceAssessment.Visibility> = [.none]
}
