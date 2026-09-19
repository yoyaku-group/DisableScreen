import Foundation

/// Tri-state error from `LidMutationService`. The mapping is the same shape
/// as `DisplayMutationService.MutationError` to keep the CLI dispatch
/// (`3` = refusal, `5` = backend failure) uniform across both axes.
public enum LidMutationError: Error, Equatable {
    case preconditionUnknown
    case noChangeRequested(target: Bool)
    case notOwned
    case backendFailed(message: String)
}
