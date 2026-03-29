import NIO

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
actor StunAsyncCore {
    struct RequestRetryConfiguration: Sendable {
        /// Initial retransmission timeout (RTO) in nanoseconds.
        var initialRtoNanoseconds: UInt64
        /// Maximum number of sends including the initial send.
        var maxSends: Int
        /// If set, caps the backoff delay.
        var maxRtoNanoseconds: UInt64?

        init(
            initialRtoNanoseconds: UInt64,
            maxSends: Int,
            maxRtoNanoseconds: UInt64? = nil
        ) {
            self.initialRtoNanoseconds = initialRtoNanoseconds
            self.maxSends = maxSends
            self.maxRtoNanoseconds = maxRtoNanoseconds
        }
    }

    struct PeerKey: Hashable, Sendable {
        enum Storage: Hashable, Sendable {
            case v4(UInt32)
            case v6([UInt8])
        }

        let storage: Storage

        init?(socketAddress: SocketAddress) {
            switch socketAddress {
            case .v4(let addr):
                self.storage = .v4(addr.address.sin_addr.s_addr)
            case .v6(let addr):
                let bytes = withUnsafeBytes(of: addr.address.sin6_addr) { raw in
                    Array(raw)
                }
                // `sockaddr_in6.sin6_addr` is 16 bytes.
                guard bytes.count == 16 else { return nil }
                self.storage = .v6(bytes)
            default:
                return nil
            }
        }
    }

    private let remoteAddress: SocketAddress

    private var outbound: NIOAsyncChannelOutboundWriter<AddressedEnvelope<ByteBuffer>>?
    private var outboundWaiters: [CheckedContinuation<Void, Error>] = []
    private var queries: [StunTransactionId: AsyncStream<StunMessage>.Continuation] = [:]
    private var allocations: [PeerKey: AsyncStream<ByteBuffer>.Continuation] = [:]
    private var closeRequested = false

    init(remoteAddress: SocketAddress) {
        self.remoteAddress = remoteAddress
    }

    func registerAllocation(peerAddress: SocketAddress) -> (PeerKey, AsyncStream<ByteBuffer>)? {
        guard let key = PeerKey(socketAddress: peerAddress) else { return nil }

        var continuation: AsyncStream<ByteBuffer>.Continuation!
        let stream = AsyncStream<ByteBuffer> { continuation = $0 }
        allocations[key] = continuation
        return (key, stream)
    }

    func unregisterAllocation(_ key: PeerKey) {
        allocations.removeValue(forKey: key)?.finish()
    }

    func requestClose() {
        closeRequested = true
        outbound?.finish()
        let waiters = outboundWaiters
        outboundWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(throwing: CancellationError())
        }
        failAllPending()
        for continuation in allocations.values {
            continuation.finish()
        }
        allocations.removeAll()
    }

    func bindOutbound(_ outbound: NIOAsyncChannelOutboundWriter<AddressedEnvelope<ByteBuffer>>) {
        if closeRequested {
            return
        }
        self.outbound = outbound
        let waiters = outboundWaiters
        outboundWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: ())
        }
    }

    private func waitUntilReady() async throws {
        if closeRequested {
            throw CancellationError()
        }
        if outbound != nil {
            return
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            outboundWaiters.append(cont)
        }
    }

    func sendRequest(_ message: StunMessage) async throws -> StunMessage {
        // Default to a small number of retransmissions.
        try await sendRequest(
            message,
            timeoutNanoseconds: nil,
            retry: .init(initialRtoNanoseconds: 500_000_000, maxSends: 1)
        )
    }

    func sendRequest(
        _ message: StunMessage,
        timeoutNanoseconds: UInt64?,
        retry: RequestRetryConfiguration
    ) async throws -> StunMessage {
        try await waitUntilReady()
        guard let outbound else {
            throw StunClientError.closed
        }
        if closeRequested {
            throw StunClientError.closed
        }

        let id = message.header.transactionId

        // Install the waiter before sending.
        var responseContinuation: AsyncStream<StunMessage>.Continuation!
        let responseStream = AsyncStream<StunMessage> { responseContinuation = $0 }
        queries[id] = responseContinuation

        // Ensure we never leak a query entry.
        defer {
            cancelQuery(transactionId: id)
        }

        let remoteAddress = self.remoteAddress

        func sendOnce() async throws {
            var buffer = ByteBuffer()
            buffer.writeStunMessage(message)
            try await outbound.write(
                AddressedEnvelope(
                    remoteAddress: remoteAddress,
                    data: buffer
                )
            )
        }

        // Send once immediately.
        do {
            try await sendOnce()
        } catch {
            throw error
        }

        // Wait for a response with optional retransmission/backoff.
        return try await withThrowingTaskGroup(of: StunMessage.self) { group in
            // Task 1: wait for inbound response.
            group.addTask {
                var iterator = responseStream.makeAsyncIterator()
                guard let msg = await iterator.next() else {
                    throw StunClientError.closed
                }
                return msg
            }

            // Task 2: retransmit / timeout.
            group.addTask {
                var rto = retry.initialRtoNanoseconds
                let maxSends = max(1, retry.maxSends)
                var sendsDone = 1

                while !Task.isCancelled {
                    // If we're not allowed to send again, treat as timeout.
                    if sendsDone >= maxSends {
                        if let timeoutNanoseconds {
                            // If a hard timeout is configured, respect it by sleeping until it fires.
                            try await Task.sleep(nanoseconds: timeoutNanoseconds)
                        } else {
                            // Give one last RTO window for a late response.
                            try await Task.sleep(nanoseconds: rto)
                        }
                        throw StunClientError.timeout
                    }

                    try await Task.sleep(nanoseconds: rto)
                    if Task.isCancelled { break }

                    // Re-send.
                    try await sendOnce()
                    sendsDone += 1

                    // Exponential backoff.
                    let next = rto &* 2
                    if let maxRto = retry.maxRtoNanoseconds {
                        rto = min(next, maxRto)
                    } else {
                        rto = next
                    }
                }

                // Group cancelled (response arrived); exit.
                throw CancellationError()
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    func sendIndication(_ message: StunMessage) async throws {
        try await waitUntilReady()
        guard let outbound else { throw CancellationError() }

        var buffer = ByteBuffer()
        buffer.writeStunMessage(message)
        try await outbound.write(
            AddressedEnvelope(
                remoteAddress: remoteAddress,
                data: buffer
            )
        )
    }

    func run(
        inbound: NIOAsyncChannelInboundStream<StunMessage>,
        outbound: NIOAsyncChannelOutboundWriter<AddressedEnvelope<ByteBuffer>>
    ) async {
        self.bindOutbound(outbound)

        do {
            for try await message in inbound {
                if closeRequested {
                    break
                }
                handleInboundMessage(message)
            }
        } catch {
            failAllPending()
        }

        // Inbound stream finished (channel closed). Ensure we unblock waiters.
        requestClose()
    }

    private func handleInboundMessage(_ message: StunMessage) {
        if message.header.type == .dataIndication {
            routeDataIndication(message)
            return
        }

        if let cont = queries.removeValue(forKey: message.header.transactionId) {
            cont.yield(message)
            cont.finish()
        }
    }

    private func routeDataIndication(_ message: StunMessage) {
        do {
            guard
                let dataAttr = message.attributes.first(where: { $0.stunType == .data }),
                let originAttr = message.attributes.first(where: { $0.stunType == .xorPeerAddress })
            else {
                return
            }

            guard
                case .data(let buffer) = try dataAttr.resolve(forTransaction: message.header.transactionId),
                case .xorPeerAddress(let address) = try originAttr.resolve(forTransaction: message.header.transactionId),
                let key = PeerKey(socketAddress: address),
                let continuation = allocations[key]
            else {
                return
            }

            continuation.yield(buffer)
        } catch {
            // Ignore malformed indications.
        }
    }

    private func cancelQuery(transactionId: StunTransactionId) {
        if let cont = queries.removeValue(forKey: transactionId) {
            cont.finish()
        }
    }

    private func failAllPending() {
        let pending = queries
        queries.removeAll()
        for (_, cont) in pending {
            cont.finish()
        }
    }
}
