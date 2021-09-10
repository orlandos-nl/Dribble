import NIO

public struct TurnAllocation {
    public let ourAddress: SocketAddress
    internal let client: TurnClient
    
    public func createChannel(for theirAddress: SocketAddress) async throws -> Channel {
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
        
        let channel = TurnAllocationChannel(
            client: client,
            allocationAddress: theirAddress
        )
        
        try await client.sender.registerTurnAllocationChannel(channel, theirAddress: theirAddress)
        
        return channel
    }
}

final class TurnAllocationChannel: Channel, ChannelCore {
    internal let client: TurnClient
    internal let allocationAddress: SocketAddress
    public let allocator: ByteBufferAllocator
    private var _pipeline: ChannelPipeline!
    
    init(client: TurnClient, allocationAddress: SocketAddress) {
        self.client = client
        self.allocationAddress = allocationAddress
        self.allocator = client.channel.allocator
        self._pipeline = ChannelPipeline(channel: self)
    }
    
    public var closeFuture: EventLoopFuture<Void> {
        client.channel.closeFuture
    }
    
    public var pipeline: ChannelPipeline {
        _pipeline
    }
    
    public var localAddress: SocketAddress? { parent?.localAddress }
    public var remoteAddress: SocketAddress? { parent?.remoteAddress }
    
    public var parent: Channel? {
        client.channel
    }
    
    public let isWritable = true
    public let isActive = true
    
    public var _channelCore: ChannelCore { self }
    
    public func localAddress0() throws -> SocketAddress {
        try client.channel._channelCore.localAddress0()
    }
    
    public func remoteAddress0() throws -> SocketAddress {
        try client.channel._channelCore.remoteAddress0()
    }
    
    public func setOption<Option>(_ option: Option, value: Option.Value) -> EventLoopFuture<Void> where Option : ChannelOption {
        fatalError("Setting option \(option) on TurnAllocationChannel is not supported")
    }
    
    func getOption<Option>(_ option: Option) -> EventLoopFuture<Option.Value> where Option : ChannelOption {
        fatalError("Getting option \(option) on TurnAllocationChannel is not supported")
    }
    
    public func register0(promise: EventLoopPromise<Void>?) {
        fatalError("not implemented \(#function)")
    }
    
    public func bind0(to: SocketAddress, promise: EventLoopPromise<Void>?) {
        fatalError("not implemented \(#function)")
    }
    
    public func connect0(to: SocketAddress, promise: EventLoopPromise<Void>?) {
        fatalError("not implemented \(#function)")
    }
    
    public func write0(_ data: NIOAny, promise: EventLoopPromise<Void>?) {
        @Sendable func run() async throws {
            var peerAddress = ByteBuffer()
            peerAddress.writeSocketAddress(self.allocationAddress, xor: true)
            
            _ = try await client.sendMessage(
                StunMessage(
                    type: .sendIndication,
                    attributes: [
                        StunAttribute(
                            type: .xorPeerAddress,
                            value: peerAddress
                        ),
                        StunAttribute(
                            type: .data,
                            value: unwrapData(data)
                        )
                    ]
                )
            )
        }
        
        if let promise = promise {
            promise.completeWithTask {
                try await run()
            }
        } else {
            Task.detached {
                try await run()
            }
        }
    }
    
    public func flush0() {
        // TODO: Packets are always flushed
    }
    
    public func read0() {
        client.channel.read()
    }
    
    public func close0(error: Error, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        fatalError()
    }
    
    public func triggerUserOutboundEvent0(_ event: Any, promise: EventLoopPromise<Void>?) {
        promise?.fail(TurnChannelError.operationUnsupported)
    }
    
    public func channelRead0(_ data: NIOAny) {
        // Do nothing
    }
    
    public func errorCaught0(error: Error) {
        // No handling needed
    }
    
    public var eventLoop: EventLoop { client.channel.eventLoop }
}
