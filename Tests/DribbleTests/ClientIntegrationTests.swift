import Testing
import NIO
import Dispatch
@testable import Dribble

@Suite
struct ClientIntegrationTests {
    @Test
    func stunClientRequestBinding_roundTripAgainstLocalStub() async throws {
        let server = try await StubStunTurnServer.start()

        let client = try await StunClient.connect(to: server.address)
        do {
            let mapped = try await client.requestBinding(addressFamily: .ipv4)

            let observedClient = try await server.waitForLastClientAddress()

            // Server echoes back the XOR-MAPPED-ADDRESS based on what it sees.
            let local = try #require(client.channel.localAddress)

            #expect(mapped.port == local.port)

            // Compare raw IPv4 address bytes (host strings can be empty when built from packed bytes).
            #expect(mapped.ipv4AddressRaw == observedClient.ipv4AddressRaw)
        } catch {
            try? await client.close()
            try? await server.stop()
            throw error
        }

        try await client.close()
        try await server.stop()
    }

    @Test
    func turnClientAllocationChannelInboundAndSendIndication() async throws {
        let server = try await StubStunTurnServer.start()

        let client = try await TurnClient.connect(to: server.address)
        do {
            let allocation = try await client.requestAllocation()
            #expect(allocation.ourAddress.port == server.relayAddress.port)
            #expect(allocation.ourAddress.ipv4AddressRaw == server.relayAddress.ipv4AddressRaw)

            let peer = try SocketAddress.makeAddressResolvingHost("127.0.0.1", port: 7777)
            let channel = try await allocation.createChannel(for: peer)

            // Arrange inbound receive.
            let inboundTask = Task { () -> String in
                for await payload in channel.inbound {
                    var buf = payload
                    return buf.readString(length: buf.readableBytes) ?? ""
                }
                return ""
            }

            // Server sends DATA-INDICATION to the client's socket.
            try await server.sendDataIndication(peer: peer, payload: ByteBuffer(string: "hello"))

            let inbound = await inboundTask.value
            #expect(inbound == "hello")

            // Client sends SEND-INDICATION (no response expected).
            try await channel.send(ByteBuffer(string: "ping"))

            let received = try await server.waitForLastSendIndicationData()
            #expect(String(decoding: received, as: UTF8.self) == "ping")

            await channel.close()
        } catch {
            try? await client.close()
            try? await server.stop()
            throw error
        }

        try await client.close()
        try await server.stop()
    }
}

// MARK: - Local STUN/TURN stub

private final class StubStunTurnServer: @unchecked Sendable {
    enum StubError: Error {
        case bindFailed
        case timeoutClientAddress
        case timeoutSendIndication
    }

    private actor State {
        var lastClientAddress: SocketAddress?
        var lastSendIndicationData: [UInt8]?

        func setLastClientAddress(_ address: SocketAddress) {
            self.lastClientAddress = address
        }

        func setLastSendIndicationData(_ data: [UInt8]) {
            self.lastSendIndicationData = data
        }
    }

    private let group: EventLoopGroup
    private let channel: Channel
    let address: SocketAddress

    /// Address used in the XOR-RELAYED-ADDRESS attribute for ALLOCATE.
    let relayAddress: SocketAddress

    private let state: State

    private init(
        group: EventLoopGroup,
        channel: Channel,
        address: SocketAddress,
        relayAddress: SocketAddress,
        state: State
    ) {
        self.group = group
        self.channel = channel
        self.address = address
        self.relayAddress = relayAddress
        self.state = state
    }

    static func start() async throws -> StubStunTurnServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        let relayAddress = try SocketAddress.makeAddressResolvingHost("127.0.0.1", port: 9999)
        let state = State()

        // Bind on loopback with an ephemeral port.
        let channel = try await DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandler(
                    StubHandler(
                        relayAddress: relayAddress,
                        state: state
                    )
                )
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()

        guard let address = channel.localAddress else {
            try await shutdownEventLoopGroup(group)
            throw StubError.bindFailed
        }

        return StubStunTurnServer(
            group: group,
            channel: channel,
            address: address,
            relayAddress: relayAddress,
            state: state
        )
    }

    func stop() async throws {
        channel.close(promise: nil)
        _ = try await channel.closeFuture.get()
        try await shutdownEventLoopGroup(group)
    }

    func waitForLastClientAddress(timeoutNanoseconds: UInt64 = 1_000_000_000) async throws -> SocketAddress {
        let deadline = DispatchTime.now().uptimeNanoseconds &+ timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if let addr = await state.lastClientAddress {
                return addr
            }
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
        throw StubError.timeoutClientAddress
    }

    func waitForLastSendIndicationData(timeoutNanoseconds: UInt64 = 1_000_000_000) async throws -> [UInt8] {
        let deadline = DispatchTime.now().uptimeNanoseconds &+ timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if let data = await state.lastSendIndicationData {
                return data
            }
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
        throw StubError.timeoutSendIndication
    }

    func sendDataIndication(peer: SocketAddress, payload: ByteBuffer) async throws {
        let client = try await waitForLastClientAddress()
        var peerAttr = ByteBuffer()
        peerAttr.writeSocketAddress(peer, xor: true)

        let message = StunMessage(
            type: .dataIndication,
            attributes: [
                StunAttribute(type: .xorPeerAddress, value: peerAttr),
                StunAttribute(type: .data, value: payload)
            ]
        )

        var buf = ByteBuffer()
        buf.writeStunMessage(message)

        try await channel.writeAndFlush(AddressedEnvelope(remoteAddress: client, data: buf)).get()
    }

    // MARK: - Handler

    private final class StubHandler: @unchecked Sendable, ChannelInboundHandler {
        typealias InboundIn = AddressedEnvelope<ByteBuffer>
        typealias OutboundOut = AddressedEnvelope<ByteBuffer>

        private let relayAddress: SocketAddress
        private let state: State

        init(
            relayAddress: SocketAddress,
            state: State
        ) {
            self.relayAddress = relayAddress
            self.state = state
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let envelope = unwrapInboundIn(data)
            var buffer = envelope.data

            Task { await state.setLastClientAddress(envelope.remoteAddress) }

            do {
                let request = try Self.parseSingleStunMessage(from: &buffer)

                switch request.header.type {
                case .bindingRequest:
                    // Echo back XOR-MAPPED-ADDRESS based on what the server sees.
                    var addrBuf = ByteBuffer()
                    addrBuf.writeSocketAddress(envelope.remoteAddress, xor: true)

                    let response = StunMessage(
                        type: .bindingResponse,
                        transactionId: request.header.transactionId,
                        attributes: [
                            StunAttribute(type: .xorMappedAddress, value: addrBuf)
                        ]
                    )

                    var out = ByteBuffer()
                    out.writeStunMessage(response)
                    context.writeAndFlush(wrapOutboundOut(AddressedEnvelope(remoteAddress: envelope.remoteAddress, data: out)), promise: nil)

                case .allocateRequest:
                    // Provide XOR-RELAYED-ADDRESS.
                    var relayBuf = ByteBuffer()
                    relayBuf.writeSocketAddress(relayAddress, xor: true)

                    let response = StunMessage(
                        type: .allocateResponse,
                        transactionId: request.header.transactionId,
                        attributes: [
                            StunAttribute(type: .xorRelayedAddress, value: relayBuf)
                        ]
                    )

                    var out = ByteBuffer()
                    out.writeStunMessage(response)
                    context.writeAndFlush(wrapOutboundOut(AddressedEnvelope(remoteAddress: envelope.remoteAddress, data: out)), promise: nil)

                case .createPermission:
                    let response = StunMessage(
                        type: .createPermissionSuccess,
                        transactionId: request.header.transactionId,
                        attributes: []
                    )

                    var out = ByteBuffer()
                    out.writeStunMessage(response)
                    context.writeAndFlush(wrapOutboundOut(AddressedEnvelope(remoteAddress: envelope.remoteAddress, data: out)), promise: nil)

                case .sendIndication:
                    if
                        let attr = request.attributes.first(where: { StunAttributeType(rawValue: $0.type) == .data }),
                        case .data(let data) = try? attr.resolve(forTransaction: request.header.transactionId)
                    {
                        let bytes = Array(data.readableBytesView)
                        Task { await state.setLastSendIndicationData(bytes) }
                    }

                default:
                    break
                }
            } catch {
                // Ignore malformed packets.
            }
        }

        private static func parseSingleStunMessage(from buffer: inout ByteBuffer) throws -> StunMessage {
            guard
                buffer.readableBytes >= 20,
                let length: UInt16 = buffer.getInteger(at: buffer.readerIndex + 2),
                buffer.readableBytes >= 20 + Int(length)
            else {
                throw StunError.invalidPacket
            }

            let endIndex = buffer.readerIndex + 20 + Int(length)

            guard
                let rawType: UInt16 = buffer.readInteger(),
                let type = StunMessageType(rawValue: rawType)
            else {
                throw StunError.invalidPacket
            }

            buffer.moveReaderIndex(forwardBy: 2)

            guard
                buffer.readInteger(as: UInt32.self) == StunMessageHeader.cookie,
                let tx = buffer.readBytes(length: 12)
            else {
                throw StunError.invalidPacket
            }

            var attributes: [StunAttribute] = []

            while buffer.readerIndex < endIndex {
                guard
                    let attrType: UInt16 = buffer.readInteger(),
                    let bodyLength: UInt16 = buffer.readInteger(),
                    let body = buffer.readSlice(length: Int(bodyLength))
                else {
                    throw StunError.invalidPacket
                }

                let padding = (4 - (Int(bodyLength) % 4)) % 4
                if buffer.readableBytes < padding {
                    throw StunError.invalidPacket
                }
                buffer.moveReaderIndex(forwardBy: padding)

                attributes.append(StunAttribute(type: attrType, value: body))
            }

            guard buffer.readerIndex == endIndex else {
                throw StunError.invalidPacket
            }

            return StunMessage(
                type: type,
                transactionId: StunTransactionId(bytes: tx),
                attributes: attributes
            )
        }
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

private extension SocketAddress {
    var ipv4AddressRaw: UInt32? {
        switch self {
        case .v4(let a):
            return a.address.sin_addr.s_addr
        default:
            return nil
        }
    }
}
