import NIOConcurrencyHelpers
import _NIOConcurrency
import NIO

public class StunClient: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// STUN/TURN request timeout in nanoseconds. `nil` disables timeouts.
        public var requestTimeoutNanoseconds: UInt64?

        /// Initial retransmission timeout (RTO) in nanoseconds.
        /// STUN RFC guidance is commonly ~500ms.
        public var requestInitialRtoNanoseconds: UInt64

        /// Maximum number of sends per request (including the initial send).
        public var requestMaxSends: Int

        /// Maximum RTO cap in nanoseconds (optional).
        public var requestMaxRtoNanoseconds: UInt64?

        public init(
            requestTimeoutNanoseconds: UInt64? = 5_000_000_000,
            requestInitialRtoNanoseconds: UInt64 = 500_000_000,
            requestMaxSends: Int = 7,
            requestMaxRtoNanoseconds: UInt64? = nil
        ) {
            self.requestTimeoutNanoseconds = requestTimeoutNanoseconds
            self.requestInitialRtoNanoseconds = requestInitialRtoNanoseconds
            self.requestMaxSends = requestMaxSends
            self.requestMaxRtoNanoseconds = requestMaxRtoNanoseconds
        }
    }

    private let eventLoopGroup: EventLoopGroup
    let channel: Channel
    private let configuration: Configuration

    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    private let core: StunAsyncCore

    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    private let runTask: Task<Void, Never>?

    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    internal var _asyncCore: StunAsyncCore { core }
    
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    internal required init(
        eventLoopGroup: EventLoopGroup,
        channel: Channel,
        configuration: Configuration,
        core: StunAsyncCore,
        runTask: Task<Void, Never>
    ) {
        self.eventLoopGroup = eventLoopGroup
        self.channel = channel
        self.configuration = configuration
        self.core = core
        self.runTask = runTask
    }

    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    internal required init(
        eventLoopGroup: EventLoopGroup,
        channel: Channel,
        configuration: Configuration,
        core: StunAsyncCore
    ) {
        self.eventLoopGroup = eventLoopGroup
        self.channel = channel
        self.configuration = configuration
        self.core = core
        self.runTask = nil
    }

    private static func makeDatagramChannel(
        group: EventLoopGroup,
        address: SocketAddress
    ) async throws -> Channel {
        try await DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandlers(
                    EnvelopToByteBufferConverter { _ in
                        _ = channel.close()
                    },
                    StunDatagramDecoder()
                )
            }
            .bind(
                host: address.protocol == .inet ? "0.0.0.0" : "::",
                port: 0)
            .get()
    }
    
    public static func connect(to address: SocketAddress, configuration: Configuration = .init()) async throws -> Self {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let channel = try await makeDatagramChannel(group: elg, address: address)

        if #available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *) {
            let asyncChannel: NIOAsyncChannel<StunMessage, AddressedEnvelope<ByteBuffer>> = try await channel.eventLoop
                .submit {
                    try NIOAsyncChannel<StunMessage, AddressedEnvelope<ByteBuffer>>(
                        wrappingChannelSynchronously: channel
                    )
                }
                .get()

            let core = StunAsyncCore(remoteAddress: address)
            let runTask = Task {
                do {
                    try await asyncChannel.executeThenClose { inbound, outbound in
                        await core.run(inbound: inbound, outbound: outbound)
                    }
                } catch {
                    await core.requestClose()
                }
            }

            return Self.init(eventLoopGroup: elg, channel: channel, configuration: configuration, core: core, runTask: runTask)
        } else {
            // NIOAsyncChannel requires Swift Concurrency.
            throw StunClientError.queryFailed
        }
    }
    
    internal func sendMessage(_ message: StunMessage) async throws -> StunMessage {
        if #available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *) {
            return try await core.sendRequest(
                message,
                timeoutNanoseconds: configuration.requestTimeoutNanoseconds,
                retry: .init(
                    initialRtoNanoseconds: configuration.requestInitialRtoNanoseconds,
                    maxSends: configuration.requestMaxSends,
                    maxRtoNanoseconds: configuration.requestMaxRtoNanoseconds
                )
            )
        } else {
            throw StunClientError.queryFailed
        }
    }

    public func close() async throws {
        if #available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *) {
            await core.requestClose()
        }
        channel.close(promise: nil)
        _ = try await channel.closeFuture.get()
        runTask?.cancel()
        try await Self.shutdownEventLoopGroup(eventLoopGroup)
    }

    /// Structured-concurrency entrypoint.
    ///
    /// This keeps protocol parsing inside minimal NIO handlers, and runs all business logic
    /// (request/response correlation, routing) outside the pipeline using `NIOAsyncChannel`.
    ///
    /// The inbound loop is run as a child task of this scope.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public static func withConnected<Result: Sendable>(
        to address: SocketAddress,
        configuration: Configuration = .init(),
        _ body: @Sendable @escaping (Self) async throws -> Result
    ) async throws -> Result {
        try await _withConnectedInternal(clientType: Self.self, to: address, configuration: configuration, body)
    }

    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    internal static func _withConnectedInternal<Client: StunClient, Result: Sendable>(
        clientType: Client.Type,
        to address: SocketAddress,
        configuration: Configuration,
        _ body: @Sendable @escaping (Client) async throws -> Result
    ) async throws -> Result {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let channel = try await makeDatagramChannel(group: elg, address: address)

            let asyncChannel: NIOAsyncChannel<StunMessage, AddressedEnvelope<ByteBuffer>> = try await channel.eventLoop
                .submit {
                    try NIOAsyncChannel<StunMessage, AddressedEnvelope<ByteBuffer>>(
                        wrappingChannelSynchronously: channel
                    )
                }
                .get()

            let core = StunAsyncCore(remoteAddress: address)
            let client = Client.init(eventLoopGroup: elg, channel: channel, configuration: configuration, core: core)

            let result = try await asyncChannel.executeThenClose { inbound, outbound in
                // Bind outbound immediately so requests can safely start.
                await core.bindOutbound(outbound)

                return try await withThrowingTaskGroup(of: Result.self) { group in
                    // Child task 1: inbound processing loop
                    group.addTask {
                        await core.run(inbound: inbound, outbound: outbound)
                        // If the inbound loop returns, treat as cancellation for the body.
                        throw CancellationError()
                    }

                    // Child task 2: user/business logic
                    group.addTask {
                        let result = try await body(client)
                        await core.requestClose()
                        return result
                    }

                    // First task to finish wins.
                    let result = try await group.next()!
                    group.cancelAll()
                    return result
                }
            }

            try await shutdownEventLoopGroup(elg)
            return result
        } catch {
            try await shutdownEventLoopGroup(elg)
            throw error
        }
    }

    private static func shutdownEventLoopGroup(_ group: EventLoopGroup) async throws {
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
    
    public func requestBinding(addressFamily: AddressFamily) async throws -> SocketAddress {
        let message = try await sendMessage(.bindingRequest(with: addressFamily))
        
        guard let addressAttribute = message.attributes.first(where: { attribute in
            switch attribute.type {
            case StunAttributeType.mappedAddress.rawValue:
                return true
            case StunAttributeType.xorMappedAddress.rawValue:
                return true
            default:
                return false
            }
        }) else {
            throw StunClientError.queryFailed
        }
        
        switch try addressAttribute.resolve(forTransaction: message.header.transactionId) {
        case .mappedAddress(let address), .xorMappedAddress(let address):
            return address
        default:
            throw StunClientError.queryFailed
        }
    }
}
