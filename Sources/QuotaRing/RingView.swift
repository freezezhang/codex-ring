import AppKit
import QuotaCore
import RingDrawing
final class RingView:NSView {
    var composition:RingComposition? { didSet { needsDisplay=true;setAccessibilityLabel(composition?.accessibilityText ?? "CodexRing 额度不可用") } }
    var onDragStart:(()->Void)?,onDragEnd:(()->Void)?,onEnter:(()->Void)?,onExit:(()->Void)?,onClick:(()->Void)?,onMenu:(()->Void)?
    private var dragPoint=NSPoint.zero,dragOrigin=NSPoint.zero
    private var dragged=false
    var positionLocked=false
    private var tracking:NSTrackingArea?
    override init(frame:NSRect) { super.init(frame:frame);setAccessibilityElement(true);setAccessibilityRole(.button) }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not used") }
    override func accessibilityPerformPress()->Bool { onClick?();return true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas();if let tracking { removeTrackingArea(tracking) }
        let area=NSTrackingArea(rect:bounds,options:[.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:self);addTrackingArea(area);tracking=area
    }
    override func mouseEntered(with event:NSEvent) { onEnter?() }
    override func mouseExited(with event:NSEvent) { onExit?() }
    override func mouseDown(with event:NSEvent) { onDragStart?();dragPoint=NSEvent.mouseLocation;dragOrigin=window?.frame.origin ?? .zero;dragged=false }
    override func mouseDragged(with event:NSEvent) {
        let p=NSEvent.mouseLocation;if hypot(p.x-dragPoint.x,p.y-dragPoint.y)>3 { dragged=true }
        window?.setFrameOrigin(DragMotion.origin(initial:dragOrigin,start:dragPoint,current:p,locked:positionLocked))
    }
    override func mouseUp(with event:NSEvent) { onDragEnd?();if !dragged { onClick?() } }
    override func rightMouseDown(with event:NSEvent) { onMenu?() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance();needsDisplay=true }
    override func draw(_ dirtyRect:NSRect) {
        let style:RingDrawingStyle = effectiveAppearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? .dark:.light
        RingPainter.draw(composition:composition,bounds:bounds,style:style)
    }
}
