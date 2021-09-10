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
