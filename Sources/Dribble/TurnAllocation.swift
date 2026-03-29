import NIO

public struct TurnAllocation {
    public let ourAddress: SocketAddress
    internal let client: TurnClient
    
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func createChannel(for theirAddress: SocketAddress) async throws -> TurnAllocationChannel {
        let transactionId = StunTransactionId()
        var xorPeerAddress = ByteBuffer()
        xorPeerAddress.writeSocketAddress(theirAddress, xor: true)
        let response = try await client.sendMessage(
            StunMessage(
                type: .createPermission,
                transactionId: transactionId,
                attributes: [
                    .init(
                        type: .xorPeerAddress,
                        value: xorPeerAddress
                    )
                ]
            )
        )
        
        guard response.header.type == .createPermissionSuccess else {
            throw TurnClientError.createPermissionFailure
        }

        let core = client._asyncCore

        guard let (key, inbound) = await core.registerAllocation(peerAddress: theirAddress) else {
            throw CancellationError()
        }

        return TurnAllocationChannel(
            client: client,
            peerAddress: theirAddress,
            key: key,
            inbound: inbound
        )
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public final class TurnAllocationChannel: @unchecked Sendable {
    private let client: TurnClient
    public let peerAddress: SocketAddress
    private let key: StunAsyncCore.PeerKey

    public let inbound: AsyncStream<ByteBuffer>

    init(
        client: TurnClient,
        peerAddress: SocketAddress,
        key: StunAsyncCore.PeerKey,
        inbound: AsyncStream<ByteBuffer>
    ) {
        self.client = client
        self.peerAddress = peerAddress
        self.key = key
        self.inbound = inbound
    }

    public func send(_ payload: ByteBuffer) async throws {
        var peerAddress = ByteBuffer()
        peerAddress.writeSocketAddress(self.peerAddress, xor: true)

        let message = StunMessage(
            type: .sendIndication,
            attributes: [
                StunAttribute(
                    type: .xorPeerAddress,
                    value: peerAddress
                ),
                StunAttribute(
                    type: .data,
                    value: payload
                )
            ]
        )

        try await client._asyncCore.sendIndication(message)
    }

    public func close() async {
        await client._asyncCore.unregisterAllocation(key)
    }
}
