import Foundation

/// A small, local, deterministic filmmaking-knowledge layer for the Director.
///
/// Every entry below is original wording written for this project — none of
/// it is copied or paraphrased from any specific published book, course, or
/// other copyrighted text. The guidance is intentionally compact and generic
/// (the kind of thing found in countless independent filmmaking references),
/// not attributed craft from a single source.
///
/// This is deliberately NOT a RAG/embedding system. There is no vector store,
/// no downloaded embedding model, and no network call: `retrieve(for:)` is a
/// synchronous, in-memory keyword/tag overlap score over a few dozen short
/// entries. That is a feature, not a placeholder — the retrieval is small
/// enough to be fully inspectable (read `entries` below, or log the IDs
/// `retrieve` returns) and fast enough to run on every planning request with
/// no measurable latency. If a real embedding-based retrieval is ever
/// justified, this function's signature is the seam to replace — callers
/// only depend on `retrieve(for:) -> [KnowledgeEntry]`.
enum AutoMovieKnowledgeBase {

    enum Category: String {
        case cinematography
        case performance
        case storytelling
    }

    struct KnowledgeEntry {
        let id: String
        let category: Category
        /// Lowercased keywords/tags this entry matches against. Kept explicit
        /// (not derived from the text) so retrieval stays predictable: the
        /// same brief always retrieves the same entries.
        let tags: [String]
        /// One to three sentences, original wording, no attribution needed.
        let guidance: String
    }

    // MARK: - Entries

    static let entries: [KnowledgeEntry] = [
        // Cinematography — shot size / composition
        KnowledgeEntry(
            id: "cine.shot-size.establish",
            category: .cinematography,
            tags: ["establish", "opening", "location", "arrival", "wide", "place", "setting"],
            guidance: "An establishing shot answers where and when before it answers who. A static frame, a slow pan, or a slow dolly all work — the point is to let the space read clearly before anything else competes for attention."
        ),
        KnowledgeEntry(
            id: "cine.shot-size.reaction",
            category: .cinematography,
            tags: ["reaction", "notices", "realizes", "surprise", "emotion"],
            guidance: "A reaction shot works best close or medium, with the camera nearly still. Movement competes with the small facial change that is the entire point of the shot."
        ),
        KnowledgeEntry(
            id: "cine.shot-size.detail",
            category: .cinematography,
            tags: ["detail", "object", "hand", "insert", "prop"],
            guidance: "A detail insert is a brief, static or near-static close view of one specific thing. It exists to make a single fact visible, not to carry its own camera performance."
        ),
        // Cinematography — camera movement
        KnowledgeEntry(
            id: "cine.movement.walk",
            category: .cinematography,
            tags: ["walk", "walking", "moves toward", "approaches", "tracking"],
            guidance: "Continuous walking or approach is well served by a tracking shot or a gentle lateral follow that matches the subject's pace, rather than a series of static reframes."
        ),
        KnowledgeEntry(
            id: "cine.movement.stillness",
            category: .cinematography,
            tags: ["pause", "hesitates", "stillness", "quiet", "still", "subtle"],
            guidance: "A locked-off camera is not a lack of choice — for a quiet or hesitant moment, stillness lets a small change in expression or posture read as the entire event of the shot."
        ),
        KnowledgeEntry(
            id: "cine.movement.push-in",
            category: .cinematography,
            tags: ["smile", "emotional", "intimate", "turns to camera", "look toward camera"],
            guidance: "A slow push-in draws attention inward as a character's feeling changes, without the abruptness of a hard cut to a closer shot."
        ),
        KnowledgeEntry(
            id: "cine.movement.avoid-noise",
            category: .cinematography,
            tags: ["subtle", "calm", "quiet", "simple"],
            guidance: "Reach for an orbit, a fast zoom, or handheld shake only when the scene itself is energetic or unstable. Applied to a calm or subtle moment, showy camera movement reads as noise rather than style."
        ),
        // Cinematography — continuity / editing grammar
        KnowledgeEntry(
            id: "cine.continuity.same-scene",
            category: .cinematography,
            tags: ["continue", "same place", "same scene", "unbroken"],
            guidance: "Two shots in the same place, at the same moment, with the same people present belong to the same continuous scene — a change in framing alone is not a reason to cut."
        ),
        KnowledgeEntry(
            id: "cine.continuity.cut-reason",
            category: .cinematography,
            tags: ["cut", "new scene", "location change", "time jump"],
            guidance: "A cut earns its place when the location changes, meaningful time passes, or the active character changes — not merely because the previous shot has run long enough."
        ),
        KnowledgeEntry(
            id: "cine.staging.one-idea",
            category: .cinematography,
            tags: ["overloaded", "complex", "multiple actions", "busy"],
            guidance: "One continuous shot reads best when it commits to one behavioral arc — a single action that develops, rather than several unrelated actions stitched together. When a moment genuinely needs several distinct actions, it usually wants to become several shots, not one long one."
        ),
        // Performance
        KnowledgeEntry(
            id: "perf.subtle-acting",
            category: .performance,
            tags: ["performance", "subtle", "smile", "expression", "acting"],
            guidance: "Subtle acting needs time more than movement: a small facial change reads as intentional only when the shot holds long enough for the audience to register the before and the after."
        ),
        KnowledgeEntry(
            id: "perf.body-language",
            category: .performance,
            tags: ["tension", "nervous", "waiting", "posture", "body language"],
            guidance: "Tension is legible in posture and stillness before it is legible in the face — weight shifting, a held breath, restrained motion — and a medium or medium-close shot with a slow or static camera keeps that readable."
        ),
        KnowledgeEntry(
            id: "perf.timing",
            category: .performance,
            tags: ["timing", "pause", "beat", "reaction"],
            guidance: "A performance beat needs a clear before-state and after-state with a visible turn between them; a shot that is too short to show the turn reads as an interrupted action rather than a completed one."
        ),
        KnowledgeEntry(
            id: "perf.dialogue-timing",
            category: .performance,
            tags: ["dialogue", "speaking", "line", "speech"],
            guidance: "A shot carrying a spoken line needs enough duration for the line itself plus a beat of visible reaction — cutting the instant the line ends leaves no room for the moment to land."
        ),
        // Storytelling
        KnowledgeEntry(
            id: "story.shot-purpose",
            category: .storytelling,
            tags: ["purpose", "why", "arbitrary", "random"],
            guidance: "Every shot should do one clear job — establish, show an action, hold a reaction, reveal something new — rather than existing simply because the sequence needed one more shot."
        ),
        KnowledgeEntry(
            id: "story.escalation",
            category: .storytelling,
            tags: ["escalation", "buildup", "climax", "arc"],
            guidance: "A short sequence reads best when each shot advances the situation slightly further than the one before it, rather than restating the same moment in different words."
        ),
        KnowledgeEntry(
            id: "story.rhythm",
            category: .storytelling,
            tags: ["rhythm", "pacing", "montage", "fast cuts"],
            guidance: "Uniform shot lengths read as mechanical. Let a shot's duration follow what it needs to show — a quiet held moment can run longer than a quick establishing beat."
        ),
        KnowledgeEntry(
            id: "story.detail-reaction",
            category: .storytelling,
            tags: ["detail", "reaction", "insert", "cutaway"],
            guidance: "A detail shot lands best when it is followed by a reaction to it (or preceded by the look that leads to it) — a detail with nothing around it can feel arbitrary."
        ),
    ]

    /// Deterministic keyword-overlap retrieval. Scores every entry by how many
    /// of its `tags` appear as substrings of `text` (case-insensitive), then
    /// returns the top `limit` entries with a nonzero score, ties broken by
    /// declaration order so results are fully reproducible. Never throws,
    /// never blocks, never touches the network — a failure mode here is
    /// simply "zero matches," and callers must treat an empty result as a
    /// normal, expected outcome (see `Sources/Services/LocalDirectorProtocol.swift`
    /// knowledge injection: the Director prompt is unchanged, not broken,
    /// when this returns `[]`).
    static func retrieve(for text: String, limit: Int = 5) -> [KnowledgeEntry] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let lower = text.lowercased()
        let scored: [(entry: KnowledgeEntry, score: Int)] = entries.map { entry in
            let score = entry.tags.reduce(0) { partial, tag in
                lower.contains(tag) ? partial + 1 : partial
            }
            return (entry, score)
        }
        return scored
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
            .prefix(max(0, limit))
            .map(\.entry)
    }

    /// Retrieval scoped to a specific shot purpose, used once a shot's
    /// purpose has already been resolved (duration/camera planning time)
    /// rather than only at Director-prompt time. Combines the purpose's own
    /// name as an extra query term with the shot's own text.
    static func retrieve(for text: String, purpose: ShotPurpose, limit: Int = 3) -> [KnowledgeEntry] {
        retrieve(for: "\(text) \(purpose.rawValue)", limit: limit)
    }
}
