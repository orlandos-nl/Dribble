import Dribble
import NIO

final class EnvelopToByteBufferConverter: ChannelInboundHandler {
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

struct PrintHandler: ByteToMessageDecoder {
    typealias InboundOut = Never
    
    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        let string = buffer.readString(length: buffer.readableBytes) ?? "error"
        print(string)
        
        return .continue
    }
    
    func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
        try decode(context: context, buffer: &buffer)
    }
}

@main
struct CLI {
    static func main() async throws {
        let client = try await TurnClient.connect(
            to: SocketAddress.makeAddressResolvingHost("10.211.55.4", port: 3478)
        )
        
        let myAddress = try await client.requestBinding(addressFamily: .ipv4)
        let allocation = try await client.requestAllocation()
        
        // Normally the other client should also find their address
        // We can skip that here, because it's the same address
        
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let proxyTargettedChannel = try await DatagramBootstrap(group: elg)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeSucceededVoidFuture()
            }.bind(
                host: myAddress.protocol == .inet ? "0.0.0.0" : "::",
                port: 0
            ).get()
        
        var theirAddress = myAddress
        theirAddress.port = proxyTargettedChannel.localAddress?.port
        let allocationChannel = try await allocation.createChannel(for: theirAddress)
        try await allocationChannel.pipeline.addHandler(ByteToMessageHandler(PrintHandler()))
        try await proxyTargettedChannel.pipeline.addHandlers(
            EnvelopToByteBufferConverter { _ in },
            ByteToMessageHandler(PrintHandler())
        )
        
        try await proxyTargettedChannel.writeAndFlush(
            AddressedEnvelope(
                remoteAddress: allocation.ourAddress,
                data: ByteBuffer(string: "Hello")
            )
        )
        
        try await allocationChannel.writeAndFlush(ByteBuffer(string: "Test"))
        
        sleep(5)
        try await proxyTargettedChannel.close()
        try await allocationChannel.close()
    }
}
