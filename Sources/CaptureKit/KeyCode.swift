/// The hardware key codes the capture and markup windows respond to. AppKit
/// only exposes them as raw numbers; named here so keyDown switches read.
enum KeyCode {
    static let returnKey: UInt16 = 36
    static let escape: UInt16 = 53
    static let delete: UInt16 = 51
    static let keypadEnter: UInt16 = 76
    static let forwardDelete: UInt16 = 117
}
