import Testing
import NIO
@testable import Dribble

@Suite
struct DribbleTests {
    @Test
    func stunDatagramDecoder_decodesTwoMessages() async throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            // Receiver bound locally.
            let receiver = try await DatagramBootstrap(group: elg)
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .channelInitializer { channel in
                    channel.eventLoop.makeSucceededVoidFuture()
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()

            let receiverAddress = try #require(receiver.localAddress)

            // Sender bound locally.
            let sender = try await DatagramBootstrap(group: elg)
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .channelInitializer { channel in
                    channel.eventLoop.makeSucceededVoidFuture()
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()

            var continuation: AsyncStream<StunMessageType>.Continuation!
            let stream = AsyncStream<StunMessageType> { continuation = $0 }

            try await receiver.pipeline.addHandlers(
                EnvelopToByteBufferConverter { _ in
                    receiver.close(promise: nil)
                },
                StunDatagramDecoder(),
                StunTypeStreamHandler(continuation: continuation)
            )

            // Send two datagrams.
            do {
                let message = StunMessage.bindingRequest(with: .ipv4)
                var buffer = ByteBuffer()
                buffer.writeStunMessage(message)
                try await sender.writeAndFlush(AddressedEnvelope(remoteAddress: receiverAddress, data: buffer)).get()
            }

            do {
                let message = StunMessage.allocationRequest()
                var buffer = ByteBuffer()
                buffer.writeStunMessage(message)
                try await sender.writeAndFlush(AddressedEnvelope(remoteAddress: receiverAddress, data: buffer)).get()
            }

            let types = try await collectTypes(from: stream, count: 2, timeoutNanoseconds: 1_000_000_000)
            #expect(types.count == 2)
            #expect(types.first == .bindingRequest)
            #expect(types.last == .allocateRequest)

            sender.close(promise: nil)
            receiver.close(promise: nil)
            _ = try await sender.closeFuture.get()
            _ = try await receiver.closeFuture.get()
            try await shutdownEventLoopGroup(elg)
        } catch {
            // Best effort cleanup; failures should not mask the original error.
            try? await shutdownEventLoopGroup(elg)
            throw error
        }
    }
}

private final class StunTypeStreamHandler: @unchecked Sendable, ChannelInboundHandler {
    typealias InboundIn = StunMessage

    private let continuation: AsyncStream<StunMessageType>.Continuation

    init(continuation: AsyncStream<StunMessageType>.Continuation) {
        self.continuation = continuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        continuation.yield(message.header.type)
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation.finish()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        continuation.finish()
        context.close(promise: nil)
    }
}

private struct TimeoutError: Error {}

private func collectTypes(
    from stream: AsyncStream<StunMessageType>,
    count: Int,
    timeoutNanoseconds: UInt64
) async throws -> [StunMessageType] {
    try await withThrowingTaskGroup(of: [StunMessageType].self) { group in
        group.addTask {
            var out: [StunMessageType] = []
            out.reserveCapacity(count)
            for await t in stream {
                out.append(t)
                if out.count == count {
                    break
                }
            }
            return out
        }

        group.addTask {
            try await Task.sleep(nanoseconds: timeoutNanoseconds)
            throw TimeoutError()
        }

        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

private func shutdownEventLoopGroup(_ group: EventLoopGroup) async throws {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        group.shutdownGracefully { error in
            if let error {
                cont.resume(throwing: error)
            } else {
                cont.resume(returning: ())
            }
        }
    }
}
