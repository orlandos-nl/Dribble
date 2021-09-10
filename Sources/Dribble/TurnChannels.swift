import NIO

struct TurnChannelData {
    // 0x4000 through 0x4FFF
    let channelNumber: ChannelNumber
    var length: UInt16 {
        UInt16(applicationData.readableBytes)
    }
    var applicationData: ByteBuffer
}

public struct ChannelNumber: RawRepresentable {
    public let rawValue: UInt16
    
    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }
    
    public init() {
        self.rawValue = .random(in: 0x4000 ... 0x4FFF)
    }
}
