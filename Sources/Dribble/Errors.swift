enum StunClientError: Error {
    case queryFailed
    case timeout
    case closed
}

enum TurnClientError: Error {
    case createPermissionFailure
}

enum TurnChannelError: Error {
    case operationUnsupported
}
