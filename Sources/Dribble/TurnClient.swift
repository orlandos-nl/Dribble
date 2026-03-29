import NIOConcurrencyHelpers
import _NIOConcurrency
import NIO

public final class TurnClient: StunClient, @unchecked Sendable {
    public func requestAllocation() async throws -> TurnAllocation {
        let message = try await sendMessage(.allocationRequest())
        
        guard let relayedAddressAttribute = message.attributes.first(where: { attribute in
            return attribute.type == StunAttributeType.xorRelayedAddress.rawValue
        }) else {
            throw StunClientError.queryFailed
        }
        
        switch try relayedAddressAttribute.resolve(forTransaction: message.header.transactionId) {
        case .xorRelayedAddress(let address):
            return TurnAllocation(
                ourAddress: address,
                client: self
            )
        default:
            throw StunClientError.queryFailed
        }
    }

    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public static func _withConnected<Result: Sendable>(
        to address: SocketAddress,
        configuration: Configuration = .init(),
        _ body: @Sendable @escaping (TurnClient) async throws -> Result
    ) async throws -> Result {
        try await StunClient._withConnectedInternal(
            clientType: TurnClient.self,
            to: address,
            configuration: configuration,
            body
        )
    }
}
