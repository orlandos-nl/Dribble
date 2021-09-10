import NIOConcurrencyHelpers
import _NIOConcurrency
import NIO

public final class TurnClient: StunClient {
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
}
