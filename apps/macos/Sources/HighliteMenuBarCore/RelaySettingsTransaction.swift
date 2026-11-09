import Foundation

public struct RelaySettingsTransactionResult: Equatable, Sendable {
    public var applied: Bool
    public var persisted: Bool
    public var failure: String?
    public var rollbackFailure: String?

    public init(
        applied: Bool,
        persisted: Bool,
        failure: String? = nil,
        rollbackFailure: String? = nil
    ) {
        self.applied = applied
        self.persisted = persisted
        self.failure = failure
        self.rollbackFailure = rollbackFailure
    }
}

/// Orders settings changes so a healthy relay is never stopped for a binary
/// that fails preflight, and a failed apply never leaves an unpersisted
/// configuration running without attempting to restore the previous one.
public enum RelaySettingsTransaction {
    @MainActor
    public static func run(
        preflight: () throws -> Void,
        apply: () async throws -> Void,
        persist: () throws -> Void,
        rollback: () async throws -> Void
    ) async -> RelaySettingsTransactionResult {
        do {
            try preflight()
        } catch {
            return RelaySettingsTransactionResult(
                applied: false,
                persisted: false,
                failure: error.localizedDescription
            )
        }

        do {
            try await apply()
        } catch {
            let rollbackFailure = await rollbackError(rollback)
            return RelaySettingsTransactionResult(
                applied: false,
                persisted: false,
                failure: error.localizedDescription,
                rollbackFailure: rollbackFailure
            )
        }

        do {
            try persist()
        } catch {
            let rollbackFailure = await rollbackError(rollback)
            return RelaySettingsTransactionResult(
                applied: false,
                persisted: false,
                failure: "Could not save app settings: \(error.localizedDescription)",
                rollbackFailure: rollbackFailure
            )
        }

        return RelaySettingsTransactionResult(applied: true, persisted: true)
    }

    @MainActor
    private static func rollbackError(_ rollback: () async throws -> Void) async -> String? {
        do {
            try await rollback()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
