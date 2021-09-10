import NIO
import XCTest
@testable import Dribble
import NIOPosix

final class DribbleTests: XCTestCase {
    func testExample() throws {
        let remoteAddress = try SocketAddress.makeAddressResolvingHost("stun.l.google.com", port: 19302)
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = try DatagramBootstrap(group: elg)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandlers([
                    EnvelopToByteBufferConverter { _ in
                        _ = channel.close()
                    },
                    ByteToMessageHandler(StunParser()),
                    
                    StunInboundHandler(errorHandler: { error in
                        XCTFail()
                    }, attributesHandler: { message in
                        for attribute in message.attributes {
                            var value = attribute.value
                            guard let type = StunAttributeType(rawValue: attribute.type) else {
                                continue
                            }
                            let attribute = try! ResolvedStunAttribute(
                                type: type,
                                transactionId: message.header.transactionId,
                                buffer: &value
                            )
                            print(attribute)
                        }
                        print(message)
                    })
                ])
            }.bind(host: remoteAddress.protocol == .inet ? "0.0.0.0" : "::", port: 14135).wait()
        
        do {
            let message = StunMessage.bindingRequest(with: .ipv6)
            var buffer = ByteBuffer()
            buffer.writeStunMessage(message)
            let envelope = AddressedEnvelope<ByteBuffer>(remoteAddress: remoteAddress, data: buffer)
            try server.writeAndFlush(envelope).wait()
        }
        
        sleep(3)
        
        do {
            let message = StunMessage.allocationRequest()
            var buffer = ByteBuffer()
            buffer.writeStunMessage(message)
            let envelope = AddressedEnvelope<ByteBuffer>(remoteAddress: remoteAddress, data: buffer)
            try server.writeAndFlush(envelope).wait()
        }
        
        try server.close().wait()
        try elg.syncShutdownGracefully()
    }
}

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

final class StunInboundHandler: ChannelInboundHandler {
    public typealias InboundIn = StunMessage
    public typealias OutboundOut = AddressedEnvelope<ByteBuffer>
    public typealias ErrorHandler = ((Error) -> ())?
    
    private let errorHandler: ErrorHandler
    private let attributesHandler:  (StunMessage) -> ()
    
    init(errorHandler: ErrorHandler, attributesHandler: @escaping (StunMessage) -> ()) {
        self.errorHandler = errorHandler
        self.attributesHandler = attributesHandler
    }
    
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        attributesHandler(self.unwrapInboundIn(data))
    }
    
    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        errorHandler?(error)
        context.close(promise: nil)
    }
}
