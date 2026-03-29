import Dribble
import NIO

final class EnvelopToByteBufferConverter: @unchecked Sendable, ChannelInboundHandler {
    public typealias InboundIn = AddressedEnvelope<ByteBuffer>
    public typealias InboundOut = ByteBuffer
    public typealias ErrorHandler = ((Error) -> ())?

    private let errorHandler: ErrorHandler

    init(errorHandler: ErrorHandler) {
        self.errorHandler = errorHandler
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = self.unwrapInboundIn(data)
        let byteBuffer = envelope.data
        context.fireChannelRead(self.wrapInboundOut(byteBuffer))
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        errorHandler?(error)
        context.close(promise: nil)
    }
}

@main
struct CLI {
    static func main() async throws {
        let address = try SocketAddress.makeAddressResolvingHost("10.211.55.4", port: 3478)
        try await TurnClient._withConnected(to: address) { client in
            let myAddress = try await client.requestBinding(addressFamily: .ipv4)
            let allocation = try await client.requestAllocation()

            let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            let proxyTargettedChannel = try await DatagramBootstrap(group: elg)
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .channelInitializer { channel in
                    channel.eventLoop.makeSucceededVoidFuture()
                }
                .bind(
                    host: myAddress.protocol == .inet ? "0.0.0.0" : "::",
                    port: 0
                )
                .get()

            var theirAddress = myAddress
            theirAddress.port = proxyTargettedChannel.localAddress?.port
            let allocationChannel = try await allocation.createChannel(for: theirAddress)

            let inboundTask = Task {
                for await inbound in allocationChannel.inbound {
                    var buffer = inbound
                    let string = buffer.readString(length: buffer.readableBytes) ?? "error"
                    print("TURN inbound: \(string)")
                }
            }

            try await proxyTargettedChannel.pipeline.addHandler(EnvelopToByteBufferConverter { _ in })

            try await proxyTargettedChannel.writeAndFlush(
                AddressedEnvelope(
                    remoteAddress: allocation.ourAddress,
                    data: ByteBuffer(string: "Hello")
                )
            )

            try await allocationChannel.send(ByteBuffer(string: "Test"))

            sleep(5)
            try await proxyTargettedChannel.close()
            try await elg.shutdownGracefully()
            await allocationChannel.close()
            inboundTask.cancel()
        }
    }
}
