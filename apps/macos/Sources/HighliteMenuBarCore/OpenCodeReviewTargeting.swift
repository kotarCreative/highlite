import Foundation

public enum OpenCodeReviewTargeting {
    public static func eligibleCandidates(_ run: OpenCodeRun) -> [OpenCodeCandidate] {
        var seen = Set<String>()
        return run.candidates.filter { candidate in
            run.eligibleSessionIds.contains(candidate.sessionId)
                && seen.insert(candidate.sessionId).inserted
        }
    }

    /// A clear rejection pins the run to the target that was actually sent.
    /// The backend refuses to retry that run against a different session.
    public static func pinnedTargetID(_ run: OpenCodeRun) -> String? {
        guard let target = run.opencodeSessionId,
              run.eligibleSessionIds.contains(target)
        else {
            return nil
        }
        return target
    }

    public static func defaultTargetID(_ run: OpenCodeRun) -> String? {
        if let pinned = pinnedTargetID(run) {
            return pinned
        }
        if let suggested = run.suggestion?.sessionId,
           eligibleCandidates(run).contains(where: { $0.sessionId == suggested }) {
            return suggested
        }
        return eligibleCandidates(run).first?.sessionId
    }

    public static func allowsTargetOverride(_ run: OpenCodeRun) -> Bool {
        pinnedTargetID(run) == nil
    }

    public static func canSubmit(_ run: OpenCodeRun, targetSessionID: String) -> Bool {
        guard !run.promptPreview.isEmpty,
              run.eligibleSessionIds.contains(targetSessionID),
              eligibleCandidates(run).contains(where: { $0.sessionId == targetSessionID })
        else {
            return false
        }
        switch run.status {
        case .suggested:
            return true
        case .failed:
            guard let pinned = pinnedTargetID(run) else { return false }
            return pinned == targetSessionID
        default:
            return false
        }
    }
}
