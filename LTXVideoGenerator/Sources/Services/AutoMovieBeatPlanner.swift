import Foundation

/// Deterministic cinematic progression for Auto Movie's no-LLM path.
///
/// When the Director returns a single shot, Auto Movie splits it into several
/// beats to reach the requested duration. That split used to reuse the brief
/// verbatim for every beat ("… — story beat 2 of 4"), so each shot described the
/// same action and the finished movie repeated one moment instead of telling a
/// story.
///
/// This planner has no story understanding and never invents plot. What it does
/// guarantee, without a language model, is that consecutive shots differ:
/// each beat states a distinct stage of the action, and the camera follows that
/// stage instead of cycling a fixed list.
///
/// Continuing beats are deliberately short. They render image-to-video from the
/// previous shot's final frame, so the scene, wardrobe and lighting already
/// arrive in the image — restating them would only fight the picture and inflate
/// the prompt.
enum AutoMovieBeatPlanner {

    /// Where a beat sits in the arc.
    enum Stage {
        case opening
        case development
        case resolution
    }

    static func stage(index: Int, count: Int) -> Stage {
        guard count > 1 else { return .opening }
        if index == 0 { return .opening }
        return index == count - 1 ? .resolution : .development
    }

    static func title(index: Int, count: Int) -> String {
        switch stage(index: index, count: count) {
        case .opening: return "Opening"
        case .development: return count > 3 ? "Development \(index)" : "Development"
        case .resolution: return "Resolution"
        }
    }

    /// The action text for a beat.
    ///
    /// The opening carries the brief because it is text-to-video and has no
    /// image to inherit. Later beats state how the action moves on, and say it
    /// in a way that works for any subject — a person reaching a door, a car
    /// being approached, someone standing up from a conversation.
    static func beatSummary(brief: String, index: Int, count: Int) -> String {
        let trimmed = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        switch stage(index: index, count: count) {
        case .opening:
            return trimmed
        case .development:
            // Middle beats are numbered from 1 so successive prompts differ in
            // wording as well as in stage. Each phrase also leads with a
            // different word, so consecutive shots do not share an opening verb.
            let step = index
            let phrases = [
                "The subject moves on from the previous moment and closes in on what comes next.",
                "Movement continues and the subject presses further ahead.",
                "The moment builds toward its turning point.",
            ]
            return phrases[(step - 1) % phrases.count]
        case .resolution:
            return "The final moment arrives and the action completes."
        }
    }

    /// Shot scale per beat. The opening establishes, the middle stays with the
    /// subject, and the closing beat sits tighter on the resolving action.
    static func shotScales(count: Int) -> [String] {
        guard count > 1 else { return ["medium"] }
        return (0..<count).map { index in
            switch stage(index: index, count: count) {
            case .opening: return "wide"
            case .development: return index % 2 == 1 ? "medium" : "medium-close-up"
            case .resolution: return "close-up"
            }
        }
    }

    /// Camera angle per beat. Varied so a longer movie does not hold one angle
    /// for three consecutive shots, which the monotony checker flags.
    static func cameraAngles(count: Int) -> [String] {
        guard count > 1 else { return ["eye-level"] }
        return (0..<count).map { index in
            switch stage(index: index, count: count) {
            case .opening, .resolution: return "eye-level"
            case .development: return index % 2 == 1 ? "low" : "high"
            }
        }
    }

    /// Camera movement per beat. Movement is chosen because it suits the beat,
    /// not to avoid stillness: a resolving moment is allowed to be static, which
    /// keeps deliberate stillness available rather than banned.
    static func cameraMovements(count: Int) -> [String] {
        guard count > 1 else { return ["static"] }
        return (0..<count).map { index in
            switch stage(index: index, count: count) {
            case .opening: return "slow push-in"
            case .development: return index % 2 == 1 ? "tracking" : "dolly"
            case .resolution: return "static"
            }
        }
    }
}
