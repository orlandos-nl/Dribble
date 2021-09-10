enum StunClientError: Error {
    case queryFailed
}

enum TurnClientError: Error {
    case createPermissionFailure
}

enum TurnChannelError: Error {
    case operationUnsupported
}
