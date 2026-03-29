import NIO

/// Decodes a single UDP datagram containing a STUN/TURN message.
///
/// This avoids using `ByteToMessageHandler`, which is explicitly non-`Sendable` in swift-nio
/// and produces Swift 6 concurrency warnings/errors.
final class StunDatagramDecoder: @unchecked Sendable, ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = StunMessage

    private let parser: StunParser

    init(parser: StunParser = StunParser()) {
        self.parser = parser
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)

        do {
            _ = try parser.decode(context: context, buffer: &buffer)
        } catch {
            context.fireErrorCaught(error)
        }
    }
}
