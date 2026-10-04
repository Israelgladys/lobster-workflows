import AppKit
import CoreGraphics

/// An invisible display, the mechanism behind Screen Sharing's headless sessions. Windows moved onto it
/// are on screen as far as WindowServer and their app are concerned, so they render, expose their
/// accessibility tree and take input, while the user never sees them. Private API, resolved at runtime;
/// the display disappears when this object is released.
final class VirtualDisplay {
    let id: CGDirectDisplayID
    private let display: AnyObject

    private typealias InitWithObject = @convention(c) (AnyObject, Selector, AnyObject) -> Unmanaged<AnyObject>?
    private typealias InitMode = @convention(c) (AnyObject, Selector, UInt, UInt, Double) -> Unmanaged<AnyObject>?
    private typealias ApplySettings = @convention(c) (AnyObject, Selector, AnyObject) -> Bool

    static var isSupported: Bool {
        ["CGVirtualDisplayDescriptor", "CGVirtualDisplay", "CGVirtualDisplaySettings", "CGVirtualDisplayMode"]
            .allSatisfy { NSClassFromString($0) != nil }
    }

    init?(name: String = "Third Hand", width: UInt = 1920, height: UInt = 1080) {
        guard Self.isSupported,
              let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
              let displayClass = NSClassFromString("CGVirtualDisplay") as? NSObject.Type,
              let settingsClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type,
              let modeClass = NSClassFromString("CGVirtualDisplayMode") as? NSObject.Type,
              let msgSend = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend") else { return nil }
        let initWithObject = unsafeBitCast(msgSend, to: InitWithObject.self)
        let initMode = unsafeBitCast(msgSend, to: InitMode.self)
        let apply = unsafeBitCast(msgSend, to: ApplySettings.self)

        let descriptor = descriptorClass.init()
        descriptor.setValue(name, forKey: "name")
        descriptor.setValue(width, forKey: "maxPixelsWide")
        descriptor.setValue(height, forKey: "maxPixelsHigh")
        descriptor.setValue(NSValue(size: NSSize(width: Double(width) * 0.26, height: Double(height) * 0.26)), forKey: "sizeInMillimeters")
        descriptor.setValue(0x7448, forKey: "productID")
        descriptor.setValue(0x7448, forKey: "vendorID")
        descriptor.setValue(1, forKey: "serialNum")
        descriptor.setValue(DispatchQueue.main, forKey: "queue")

        guard let allocated = displayClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
              let display = initWithObject(allocated, NSSelectorFromString("initWithDescriptor:"), descriptor)?.takeRetainedValue(),
              let modeAllocated = modeClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
              let mode = initMode(modeAllocated, NSSelectorFromString("initWithWidth:height:refreshRate:"), width, height, 60)?.takeRetainedValue()
        else { return nil }
        let settings = settingsClass.init()
        settings.setValue(0, forKey: "hiDPI")
        settings.setValue([mode], forKey: "modes")
        guard apply(display, NSSelectorFromString("applySettings:"), settings),
              let id = (display as? NSObject)?.value(forKey: "displayID") as? NSNumber, id.uint32Value != 0 else { return nil }
        self.display = display
        self.id = id.uint32Value
    }

    var bounds: CGRect { CGDisplayBounds(id) }
}
