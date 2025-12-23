import Foundation

/// Unified Protocol for BLEDDM / BLEDOM / Lotus Lantern Controllers
/// Supports both short (3-8 byte) and long (9-byte) command formats.
struct LEDProtocol {
    
    // Lotus Lantern X "App Mode" Priming Packets (Unlocks Interactive BLE)
    static let primingPackets: [[UInt8]] = [
        [0x7E, 0x00, 0x03, 0x25, 0x00, 0x00, 0x00, 0x00, 0xEF], // mode init
        [0x7E, 0x00, 0x06, 0x01, 0x00, 0x00, 0x00, 0x00, 0xEF], // scene init
        [0x7E, 0x00, 0x05, 0x03, 0x00, 0x00, 0x00, 0x00, 0xEF]  // fake black color
    ]
    
    enum CommandType: UInt8 {
        case power = 0x04
        case brightness = 0x01
        case speed = 0x02
        case color = 0x05
        case mode = 0x06
    }
    
    enum ProtocolVariant: Int, CaseIterable {
        case a = 0 // LinuxThings / Verified Primary (F0)
        case b = 1 // BLEDOM Variant (01 FF)
        case c = 2 // ELK Variant (04 04)
        case d = 3 // Simple / Alternative (01 Power)
    }

    // MARK: - Power
    static func power(on: Bool, variant: ProtocolVariant) -> [UInt8] {
        switch variant {
        case .a:
            // ON: 7E 00 04 F0 00 01 FF 00 EF / OFF: 7E 00 04 00 00 00 FF 00 EF
            return on ? [0x7E, 0x00, 0x04, 0xF0, 0x00, 0x01, 0xFF, 0x00, 0xEF] 
                      : [0x7E, 0x00, 0x04, 0x00, 0x00, 0x00, 0xFF, 0x00, 0xEF]
        case .b:
            // ON: 7E 00 04 01 FF 00 00 00 EF / OFF: Same as A
            return on ? [0x7E, 0x00, 0x04, 0x01, 0xFF, 0x00, 0x00, 0x00, 0xEF]
                      : [0x7E, 0x00, 0x04, 0x00, 0x00, 0x00, 0xFF, 0x00, 0xEF]
        case .c:
            // ON: 7E 04 04 01 00 00 FF 00 EF / OFF: Same as A
            return on ? [0x7E, 0x04, 0x04, 0x01, 0x00, 0x00, 0xFF, 0x00, 0xEF]
                      : [0x7E, 0x00, 0x04, 0x00, 0x00, 0x00, 0xFF, 0x00, 0xEF]
        case .d:
            // ON: 7E 00 01 FF 00 00 00 00 EF / OFF: 7E 00 01 00 00 00 00 00 EF
            return on ? [0x7E, 0x00, 0x01, 0xFF, 0x00, 0x00, 0x00, 0x00, 0xEF]
                      : [0x7E, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0xEF]
        }
    }
    
    // MARK: - Color
    static func color(r: Int, g: Int, b: Int, variant: ProtocolVariant, isGRB: Bool = false) -> [UInt8] {
        let rVal = UInt8(clamping: r)
        let gVal = UInt8(clamping: g)
        let bVal = UInt8(clamping: b)
        
        // Exact 9-byte: 7E 00 05 03 R G B 00 EF
        if isGRB {
            return [0x7E, 0x00, 0x05, 0x03, gVal, rVal, bVal, 0x00, 0xEF]
        }
        return [0x7E, 0x00, 0x05, 0x03, rVal, gVal, bVal, 0x00, 0xEF]
    }
    
    // MARK: - Brightness
    static func brightness(_ value: Int, variant: ProtocolVariant) -> [UInt8] {
        let val = UInt8(clamping: value)
        switch variant {
        case .b:
            // 7E 00 01 ZZ FF 00 00 00 EF
            return [0x7E, 0x00, 0x01, val, 0xFF, 0x00, 0x00, 0x00, 0xEF]
        default:
            // 7E 00 01 ZZ 00 00 00 00 EF
            return [0x7E, 0x00, 0x01, val, 0x00, 0x00, 0x00, 0x00, 0xEF]
    }
    
    // MARK: - Speed
    static func speed(_ value: Int, variant: ProtocolVariant = .a) -> [UInt8] {
        let val = UInt8(clamping: value)
        // Standard 9-byte speed: 7E 00 02 SS 00 00 00 00 EF
        return [0x7E, 0x00, 0x02, val, 0x00, 0x00, 0x00, 0x00, 0xEF]
    }
    
    // MARK: - Mode
    static func mode(_ value: UInt8, variant: ProtocolVariant = .a) -> [UInt8] {
        // Standard 9-byte mode: 7E 00 06 MM 00 00 00 00 EF
        return [0x7E, 0x00, 0x06, value, 0x00, 0x00, 0x00, 0x00, 0xEF]
    }
}
