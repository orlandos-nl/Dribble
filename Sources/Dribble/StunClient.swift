import NIOConcurrencyHelpers
import _NIOConcurrency
import NIO

public class StunClient {
    let channel: Channel
    let sender: StunMessageSender
    
    internal required init(channel: Channel, sender: StunMessageSender) {
        self.channel = channel
        self.sender = sender
    }
    
    public static func connect(to address: SocketAddress) async throws -> Self {
        let sender = StunInboundHandler(remoteAddress: address)
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let channel = try await DatagramBootstrap(group: elg)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandlers(
                    EnvelopToByteBufferConverter { _ in
                        _ = channel.close()
                    },
                    ByteToMessageHandler(StunParser()),
                    sender
                )
            }.bind(
                host: address.protocol == .inet ? "0.0.0.0" : "::",
                port: 0
            ).get()
        
        return Self.init(channel: channel, sender: sender)
    }
    
    internal func sendMessage(_ message: StunMessage) async throws -> StunMessage {
        try await sender.sendMessage(message, on: channel)
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
