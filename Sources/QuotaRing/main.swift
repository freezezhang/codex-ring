import AppKit
let application = NSApplication.shared
let delegate = RingApplication()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
