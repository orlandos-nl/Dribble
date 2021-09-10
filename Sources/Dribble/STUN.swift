import CryptoKit
import NIO
import NIOFoundationCompat
import NIOPosix

enum StunError: Error {
    case invalidAttributeFormat, invalidPacket, unsupported, invalidResponse, unknownAttribute
}

public enum StunMessageType: UInt16 {
    // STUN Spec
    case bindingRequest = 0x0001
    case bindingResponse = 0x0101
    case bindingErrorResponse = 0x0111
    case sharedSecretRequest = 0x0002
    case sharedSecretResponse = 0x0102
    case sharedSecretErrorResponse = 0x0112
    
    // TURN Spec
    case allocateRequest = 0x003
    case allocateResponse = 0x103
    case send = 0x006
    case sendIndication = 0x016
    case dataRequest = 0x007
    case dataIndication = 0x017
    
    case createPermission = 0x008
    case createPermissionSuccess = 0x108
    
    case channelBind = 0x009
    case channelBindSuccess = 0x109
}

public struct StunParser: ByteToMessageDecoder {
    public typealias InboundOut = StunMessage
    
    public init() {}
    
    public func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard
            buffer.readableBytes >= 20,
            let length: UInt16 = buffer.getInteger(at: 2),
            buffer.readableBytes >= 20 + Int(length)
        else {
            return .needMoreData
        }
        
        let endIndex = buffer.readerIndex + 20 + Int(length)
        
        guard
            let _type: UInt16 = buffer.readInteger(),
            let type = StunMessageType(rawValue: _type)
        else {
            throw StunError.invalidPacket
        }
        
        buffer.moveReaderIndex(forwardBy: 2)
        
        guard
            buffer.readInteger() == StunMessageHeader.cookie,
            let transactionId = buffer.readBytes(length: 12)
        else {
            throw StunError.invalidPacket
        }
        
        var attributes = [StunAttribute]()
        while buffer.readableBytes > 0 && buffer.readerIndex <= endIndex {
            guard
                let type: UInt16 = buffer.readInteger(),
                let bodyLength: UInt16 = buffer.readInteger(),
                let body = buffer.readSlice(length: Int(bodyLength))
            else {
                throw StunError.invalidPacket
            }
            
            let paddingLength = (4 - (Int(bodyLength) % 4)) % 4
            
            if buffer.readableBytes < paddingLength {
                throw StunError.invalidPacket
            }
            
            buffer.moveReaderIndex(forwardBy: paddingLength)
            
            attributes.append(StunAttribute(type: type, value: body))
        }
        
        guard buffer.readerIndex == endIndex else {
            throw StunError.invalidPacket
        }
        
        let packet = StunMessage(
            type: type,
            transactionId: StunTransactionId(bytes: transactionId),
            attributes: attributes
        )
        
        context.fireChannelRead(wrapInboundOut(packet))
        return .continue
    }
    
    public func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
        return try decode(context: context, buffer: &buffer)
    }
}

public struct StunTransactionId: Hashable {
    internal var bytes: [UInt8]
    
    init(bytes: [UInt8]) {
        assert(bytes.count == 12)
        self.bytes = bytes
    }
    
    public init() {
        self.bytes = .init(unsafeUninitializedCapacity: 12, initializingWith: { buffer, initializedCount in
            for i in 0..<12 {
                buffer[i] = .random(in: .min ..< .max)
            }
            
            initializedCount = 12
        })
    }
}

public struct StunMessageHeader {
    static let cookieArray: [UInt8] = [0x21, 0x12, 0xA4, 0x42]
    static let cookieHighBits: UInt16 = 0x2112
    static let cookie: UInt32 = 0x2112A442
    
    public let type: StunMessageType
    
    /// Length of the body, not including this 20 byte header
    var length: UInt16
    
    var cookie: UInt32 { Self.cookie }
    public let transactionId: StunTransactionId
}

public enum StunAttributeType: UInt16 {
    // STUN spec
    case mappedAddress = 0x0001
    case username = 0x0006
    case messageIntegrity = 0x0008
    case errorCode = 0x0009
    case unknown = 0x000a
    case realm = 0x0014
    case nonce = 0x0015
    case xorMappedAddress = 0x0020
    case software = 0x8022
    case alternateServer = 0x8023
    case fingerprint = 0x8028
    
    // TURN spec
    case channelNumber = 0x000C
    case lifetime = 0x000D
    case xorPeerAddress = 0x0012
    case data = 0x0013
    case xorRelayedAddress = 0x0016
    case requestedAddressFamily = 0x0017
    case evenPort = 0x0018
    case requestedTransport = 0x0019
    case dontFragment = 0x001A
    case reservationToken = 0x0022
    case additionalAddressFamily = 0x8000
    case addressErrorCode = 0x8001
    case icmp = 0x8004
}

public enum AddressFamily: UInt8 {
    case ipv4 = 0x01
    case ipv6 = 0x02
}

public enum ResolvedStunAttribute {
    // 0                   1                   2                   3
    // 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |0 0 0 0 0 0 0 0|    Family     |           Port                |
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |                                                               |
    // |                 Address (32 bits or 128 bits)                 |
    // |                                                               |
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    
    /// The above graph applies here
    case mappedAddress(SocketAddress)
    
    // MUST be the same IP address family I.E. ipv4/ipv6
    case alternateServer(SocketAddress)
    
    /// The same graph, but now we XOR it with the magic cookie
    /// Port is XOR-ed with the two highest bits of the magic cookie
    /// IPv4 is xor-ed byte-for-byte from front to back
    /// IPv6 is xor-ed with the concatenation of the cookie + transaction ID in network byte order
    case xorMappedAddress(SocketAddress)
    case xorPeerAddress(SocketAddress)
    case xorRelayedAddress(SocketAddress)
    
    /// UTF-8 encoded string less than 513 bytes & SASLprepped
    /// https://datatracker.ietf.org/doc/html/rfc4013
    case username(String)
    
    /// Max 128 characters, 763 bytes
    case realm(String)
    
    /// Max 128 characters, 763 bytes
    case nonce(String)
    
    /// Max 128 characters, 763 bytes
    case software(String)
    
    case messageIntegrity([UInt8])
    
    // - MARK: TURN
    
    case channelNumber(ChannelNumber)
    
    /// Allocation lifetime if not refreshed, in seconds
    case lifetime(UInt32)
    
    case icmp
    case data(ByteBuffer)
    case requestedAddressFamily(AddressFamily)
    case evenPort(Bool)
    case dontFragment
    
    public init(
        type: StunAttributeType,
        transactionId: StunTransactionId,
        buffer: inout ByteBuffer
    ) throws {
        func parseXorAddress() throws -> SocketAddress {
            guard
                buffer.readInteger(as: UInt8.self) == 0,
                let familyType: UInt8 = buffer.readInteger(),
                let family = AddressFamily(rawValue: familyType),
                var port: UInt16 = buffer.readInteger(),
                buffer.readableBytes == (family == .ipv4 ? 4 : 16)
            else {
                throw StunError.invalidAttributeFormat
            }
            
            port ^= StunMessageHeader.cookieHighBits
            let addressBuffer: ByteBuffer
            
            switch family {
            case .ipv4:
                guard var address: UInt32 = buffer.readInteger() else {
                    throw StunError.invalidAttributeFormat
                }
                
                address ^= StunMessageHeader.cookie
                addressBuffer = ByteBuffer(integer: address)
            case .ipv6:
                guard var address = buffer.readBytes(length: 16) else {
                    throw StunError.invalidAttributeFormat
                }
                
                for i in 0..<4 {
                    address[i] ^= StunMessageHeader.cookieArray[i]
                }
                
                for i in 4..<16 {
                    address[i] ^= transactionId.bytes[i - 4]
                }
                
                addressBuffer = ByteBuffer(bytes: address)
            }
            
            return try SocketAddress(
                packedIPAddress: addressBuffer,
                port: Int(port)
            )
        }
        
        func parseAddress() throws -> SocketAddress {
            guard
                buffer.readInteger(as: UInt8.self) == 0,
                let familyType: UInt8 = buffer.readInteger(),
                let family = AddressFamily(rawValue: familyType),
                let port: UInt16 = buffer.readInteger(),
                buffer.readableBytes == (family == .ipv4 ? 4 : 16)
            else {
                throw StunError.invalidAttributeFormat
            }
            
            return try SocketAddress(
                packedIPAddress: buffer,
                port: Int(port)
            )
        }
        
        switch type {
        case .mappedAddress:
            self = try .mappedAddress(parseAddress())
        case .xorMappedAddress:
            self = try .mappedAddress(parseXorAddress())
        case .username:
            throw StunError.unsupported
        case .messageIntegrity:
            guard let sha1Hash = buffer.readBytes(length: 20) else {
                throw StunError.invalidAttributeFormat
            }
            
            self = .messageIntegrity(sha1Hash)
        case .errorCode:
            throw StunError.unsupported
        case .unknown:
            // Only present in errors with code 420
            throw StunError.unsupported
        case .realm:
            guard
                buffer.readableBytes <= 763,
                let realm = buffer.readString(length: buffer.readableBytes),
                realm.count <= 128
            else {
                throw StunError.invalidAttributeFormat
            }
            
            self = .realm(realm)
        case .nonce:
            guard
                buffer.readableBytes <= 763,
                let nonce = buffer.readString(length: buffer.readableBytes),
                nonce.count <= 128
            else {
                throw StunError.invalidAttributeFormat
            }
            
            self = .nonce(nonce)
        case .software:
            guard
                buffer.readableBytes <= 763,
                let software = buffer.readString(length: buffer.readableBytes),
                software.count <= 128
            else {
                throw StunError.invalidAttributeFormat
            }
            
            self = .software(software)
        case .alternateServer:
            // MUST be the same IP address family I.E. ipv4/ipv6
            self = try .alternateServer(parseAddress())
        case .fingerprint:
            throw StunError.unsupported
        case .channelNumber:
            guard
                let channelNumber: UInt16 = buffer.readInteger(),
                buffer.readInteger(as: UInt16.self) == 0
            else {
                throw StunError.invalidAttributeFormat
            }
            
            self = .channelNumber(ChannelNumber(rawValue: channelNumber))
        case .lifetime:
            guard let lifetime: UInt32 = buffer.readInteger() else {
                throw StunError.invalidAttributeFormat
            }
            
            self = .lifetime(lifetime)
        case .xorPeerAddress:
            self = try .xorPeerAddress(parseXorAddress())
        case .data:
            self = .data(buffer.readSlice(length: buffer.readableBytes)!)
        case .xorRelayedAddress:
            self = try .xorRelayedAddress(parseXorAddress())
        case .requestedAddressFamily:
            guard
                let _family: UInt8 = buffer.readInteger(),
                let family = AddressFamily(rawValue: _family),
                buffer.readInteger(as: UInt8.self) == 0,
                buffer.readInteger(as: UInt8.self) == 0,
                buffer.readInteger(as: UInt8.self) == 0
            else {
                throw StunError.invalidAttributeFormat
            }
            
            self = .requestedAddressFamily(family)
        case .evenPort:
            guard let _evenPort: UInt8 = buffer.readInteger() else {
                throw StunError.invalidAttributeFormat
            }
            
            self = .evenPort(_evenPort & 0b1 == 0b1)
        case .requestedTransport:
            throw StunError.unsupported
        case .dontFragment:
            self = .dontFragment
        case .reservationToken:
            throw StunError.unsupported
        case .additionalAddressFamily:
            throw StunError.unsupported
        case .addressErrorCode:
            throw StunError.unsupported
        case .icmp:
            throw StunError.unsupported
        }
    }
}

public struct StunAttribute {
    public let type: UInt16
    var stunType: StunAttributeType? {
        StunAttributeType(rawValue: type)
    }
    var length: UInt16 {
        UInt16(value.readableBytes)
    }
    public internal(set) var value: ByteBuffer
    
    init(
        type: UInt16,
        value: ByteBuffer
    ) {
        self.type = type
        self.value = value
    }
    
    init(
        type: StunAttributeType,
        value: ByteBuffer
    ) {
        self.type = type.rawValue
        self.value = value
    }
    
    func resolve(forTransaction transactionId: StunTransactionId) throws -> ResolvedStunAttribute {
        guard let type = StunAttributeType(rawValue: type) else {
            // Unknown type
            throw StunError.unknownAttribute
        }
        
        var value = value
        
        return try ResolvedStunAttribute(
            type: type,
            transactionId: transactionId,
            buffer: &value
        )
    }
}

public struct StunMessage {
    public internal(set) var header: StunMessageHeader
    public internal(set) var attributes: [StunAttribute]
    var body: ByteBuffer
    private var providesIntegrity = false
    
    // TODO: Fingerprint?
    private mutating func provideSHA1Integrity(with hmac: inout HMAC<Insecure.SHA1>) {
        assert(!providesIntegrity)
        providesIntegrity = true
        
        // Update the header length, that's needed for the integrity hashing
        // 4 byte attribute header, 20 byte hash length
        self.header.length += 24
        
        // Write the body except the new attribute
        // This needs to be hashed
        // That includes the length of the integrity attribute
        var newBody = ByteBuffer()
        newBody.writeStunMessage(self)
        
        // Create the hash
        hmac.update(data: newBody.readableBytesView)
        let hash = hmac.finalize()
        
        // The attribute to be added
        let attribute = StunAttribute(
            type: .messageIntegrity,
            value: ByteBuffer(bytes: hash)
        )
        
        // Add the attribute to the body & attributes list
        attributes.append(attribute)
        newBody.writeAttribute(attribute)
        
        // Set the new body, header was already updated
        self.body = newBody
    }
    
    public mutating func provideSHA1Integrity(
        username: String,
        realm: String,
        password: String
    ) {
        let credentials = Insecure.MD5.hash(
            data: "\(username):\(realm):\(password)".data(using: .utf8)!
        )
        
        var hmac = HMAC<Insecure.SHA1>(
            key: SymmetricKey(data: credentials)
        )
        
        provideSHA1Integrity(with: &hmac)
    }
    
    public mutating func provideSHA1Integrity(
        username: String,
        password: String
    ) {
        var hmac = HMAC<Insecure.SHA1>(
            key: SymmetricKey(data: password.data(using: .utf8)!)
        )
        
        provideSHA1Integrity(with: &hmac)
    }

    init(
        type: StunMessageType,
        transactionId: StunTransactionId = .init(),
        attributes: [StunAttribute]
    ) {
        self.attributes = attributes
        
        var buffer = ByteBuffer()
        
        for attribute in attributes {
            buffer.writeAttribute(attribute)
        }
        
        self.body = buffer
        self.header = StunMessageHeader(
            type: type,
            length: UInt16(buffer.readableBytes),
            transactionId: transactionId
        )
    }
    
    public static func bindingRequest(with family: AddressFamily) -> StunMessage {
        return StunMessage(
            type: .bindingRequest,
            attributes: []
        )
    }
    
    public static func allocationRequest() -> StunMessage {
        return StunMessage(
            type: .allocateRequest,
            attributes: [
                // 17 is UDP
                .init(type: .requestedTransport, value: ByteBuffer(bytes: [17, 0, 0, 0]))
            ]
        )
    }
}

// TODO: Retransmit over UDP

extension ByteBuffer {
    mutating func writeAttribute(_ attribute: StunAttribute) {
        writeInteger(attribute.type)
        writeInteger(attribute.length)
        writeImmutableBuffer(attribute.value)
    }
    
    mutating func writeSocketAddress(_ address: SocketAddress, xor: Bool) {
        writeInteger(0x00 as UInt8)
        
        switch address {
        case .v4(let iPv4Address):
            writeInteger(AddressFamily.ipv4.rawValue)
            var xorPort = iPv4Address.address.sin_port.bigEndian
            xorPort ^= StunMessageHeader.cookieHighBits
            writeInteger(xorPort)
            
            var address = iPv4Address.address.sin_addr.s_addr.bigEndian
            address ^= StunMessageHeader.cookie
            writeInteger(address)
        case .v6(let iPv6Address):
            writeInteger(AddressFamily.ipv6.rawValue)
            let port = iPv6Address.address.sin6_port ^ StunMessageHeader.cookieHighBits
            writeInteger(port)
            
            withUnsafeBytes(of: iPv6Address.address.sin6_addr) { buffer in
                let buffer = buffer.bindMemory(to: UInt32.self)
                assert(buffer.count == 4)
                
                for i in 0..<4 {
                    self.writeInteger(buffer[i], endianness: .little)
                }
            }
        case .unixDomainSocket:
            fatalError("Unsupported SocketAddress")
        }
    }
    
    mutating func writeStunMessage(_ message: StunMessage) {
        reserveCapacity(writerIndex + 20 + message.body.readableBytes)
        writeInteger(message.header.type.rawValue)
        writeInteger(message.header.length)
        writeInteger(message.header.cookie)
        writeBytes(message.header.transactionId.bytes)
        writeImmutableBuffer(message.body)
        
        let padding = (4 - (message.body.readableBytes % 4)) % 4
        writeBytes([UInt8](repeating: 0x00, count: padding))
    }
}
