import Foundation

/// WindowServer and display bounds must both use global, top-left coordinates.
/// A normal maximized window fits the work area; a fullscreen window also
/// occupies the menu-bar/Dock area. No window titles or images are needed.
public enum FullscreenDetection {
    public static func coversDisplay(window:CGRect,display:CGRect,topInset:CGFloat = 0)->Bool {
        guard window.width > 0,window.height > 0,display.width > 0,display.height > 0 else { return false }
        let tolerance:CGFloat=1
        let fillsWidth=abs(window.minX-display.minX) <= tolerance && abs(window.maxX-display.maxX) <= tolerance
        let fillsBottom=abs(window.maxY-display.maxY) <= tolerance
        let fillsTop=abs(window.minY-display.minY) <= tolerance
        // A notched display may reserve its camera housing even in fullscreen.
        let fillsSafeTop=topInset > 0 && abs(window.minY-(display.minY+topInset)) <= tolerance
        return fillsWidth && fillsBottom && (fillsTop || fillsSafeTop)
    }
}
