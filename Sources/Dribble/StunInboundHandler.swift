import NIO
import _NIOConcurrency

protocol StunMessageSender {
    func sendMessage(_ message: StunMessage, on channel: Channel) async throws -> StunMessage
    func registerTurnAllocationChannel(_ channel: TurnAllocationChannel, theirAddress: SocketAddress) async throws
}

final class StunInboundHandler: ChannelInboundHandler, StunMessageSender {
    public typealias InboundIn = StunMessage
    public typealias OutboundOut = AddressedEnvelope<ByteBuffer>
    
    let remoteAddress: SocketAddress
    var queries = [StunTransactionId: EventLoopPromise<StunMessage>]()
    var allocations = [(SocketAddress, Channel)]()
    
    init(remoteAddress: SocketAddress) {
        self.remoteAddress = remoteAddress
    }
    
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = self.unwrapInboundIn(data)
        
        if message.header.type == .dataIndication {
            do {
                if
                    let data = message.attributes.first(where: { $0.stunType == .data }),
                    let origin = message.attributes.first(where: { $0.stunType == .xorPeerAddress }),
                    case .data(let buffer) = try data.resolve(forTransaction: message.header.transactionId),
                    case .xorPeerAddress(let address) = try origin.resolve(forTransaction: message.header.transactionId)
                {
                    let allocation = allocations.first(where: { allocation in
                        switch (allocation.0, address) {
                        case (.v4(let lhs), .v4(let rhs)):
                            return lhs.address.sin_addr.s_addr == rhs.address.sin_addr.s_addr
                        case (.v6(let lhs), .v6(let rhs)):
                        #if swift(>=5.5) && os(Linux)
                            return lhs.address.sin6_addr.__in6_u.__u6_addr32 == rhs.address.sin6_addr.__in6_u.__u6_addr32
                        #else
                             return lhs.address.sin6_addr.__u6_addr.__u6_addr32 == rhs.address.sin6_addr.__u6_addr.__u6_addr32
                        #endif
                        case (.v4, _), (.v6, _), (.unixDomainSocket, _),
                            (_, .v4), (_, .v6), (_, .unixDomainSocket):
                            return false
                        }
                    })
                    allocation?.1.pipeline.fireChannelRead(NIOAny(buffer))
                }
            } catch {
                print(error)
            }
        } else if let query = queries.removeValue(forKey: message.header.transactionId) {
            query.succeed(message)
        }
    }
    
    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        for query in queries.values {
            query.fail(error)
        }
        
        queries.removeAll()
        allocations.removeAll()
        context.close(promise: nil)
    }

    func registerTurnAllocationChannel(_ channel: TurnAllocationChannel, theirAddress: SocketAddress) async throws {
        allocations.append((theirAddress, channel))
    }
    
    func sendMessage(_ message: StunMessage, on channel: Channel) async throws -> StunMessage {
        var data = ByteBuffer()
        data.writeStunMessage(message)
        let promise = channel.eventLoop.makePromise(of: StunMessage.self)
        self.queries[message.header.transactionId] = promise
        return try await channel.writeAndFlush(
            AddressedEnvelope(
                remoteAddress: remoteAddress,
                data: data
            )
        ).flatMap {
            promise.futureResult
        }.get()
    }
}
