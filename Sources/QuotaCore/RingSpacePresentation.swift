import Foundation

public enum RingSurface:Equatable { case desktop,fullscreen }

/// Keep the ordinary desktop anchor while temporarily presenting over fullscreen.
/// Opening our own settings must not be mistaken for leaving the fullscreen Space.
public struct RingSpacePresentation {
    public private(set) var surface:RingSurface = .desktop
    public init() {}
    @discardableResult public mutating func observe(systemIsFullscreen:Bool,ownAppIsActive:Bool)->RingSurface {
        if !ownAppIsActive { surface=systemIsFullscreen ? .fullscreen:.desktop }
        return surface
    }
}
