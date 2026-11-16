import AppKit
import QuotaCore
import RingDrawing
final class RingView:NSView {
    var composition:RingComposition? { didSet { needsDisplay=true;setAccessibilityLabel(composition?.accessibilityText ?? L10n.string("ring.unavailable.a11y")) } }
    var onDragStart:(()->Void)?,onDragEnd:(()->Void)?,onEnter:(()->Void)?,onExit:(()->Void)?,onClick:(()->Void)?
    var onMenu:((NSEvent?)->Void)?
    private var dragPoint=NSPoint.zero,dragOrigin=NSPoint.zero
    private var dragged=false
    private var contextClick=false
    var positionLocked=false
    var coversNativeUsage=false { didSet { if oldValue != coversNativeUsage { needsDisplay=true } } }
    var constrainDragOrigin:((NSPoint)->NSPoint)?
    private var tracking:NSTrackingArea?
    var hoverDetails="" { didSet {
        if hoverDetails != oldValue,hoverTip?.isVisible == true,let window { hoverTip?.show(text:hoverDetails,beside:window) }
    } }
    private var hoverTip:RingHoverTip?
    private var hoverWork:DispatchWorkItem?
    func dismissHover() { hoverWork?.cancel();hoverWork=nil;hoverTip?.hide() }
    override func viewWillMove(toWindow newWindow:NSWindow?) { dismissHover();super.viewWillMove(toWindow:newWindow) }
    override init(frame:NSRect) { super.init(frame:frame);setAccessibilityElement(true);setAccessibilityRole(.button) }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not used") }
    override func acceptsFirstMouse(for event:NSEvent?)->Bool { true }
    override func accessibilityPerformPress()->Bool { dismissHover();onClick?();return true }
    override func accessibilityPerformShowMenu()->Bool { dismissHover();onMenu?(nil);return true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas();if let tracking { removeTrackingArea(tracking) }
        let area=NSTrackingArea(rect:bounds,options:[.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:self);addTrackingArea(area);tracking=area
    }
    override func mouseEntered(with event:NSEvent) {
        onEnter?();dismissHover()
        let work=DispatchWorkItem { [weak self] in
            guard let self,let window=self.window,window.isVisible,window.isOnActiveSpace else { return }
            if self.hoverTip == nil { self.hoverTip=RingHoverTip() }
            self.hoverTip?.show(text:self.hoverDetails,beside:window)
        }
        hoverWork=work;DispatchQueue.main.asyncAfter(deadline:.now()+0.35,execute:work)
    }
    override func mouseExited(with event:NSEvent) { dismissHover();onExit?() }
    override func mouseDown(with event:NSEvent) {
        dismissHover();contextClick=event.modifierFlags.contains(.control)
        if contextClick { onMenu?(event);return }
        onDragStart?();dragPoint=NSEvent.mouseLocation;dragOrigin=window?.frame.origin ?? .zero;dragged=false
    }
    override func mouseDragged(with event:NSEvent) {
        guard !contextClick else { return }
        let p=NSEvent.mouseLocation;if hypot(p.x-dragPoint.x,p.y-dragPoint.y)>3 { dragged=true }
        let origin=DragMotion.origin(initial:dragOrigin,start:dragPoint,current:p,locked:positionLocked)
        window?.setFrameOrigin(constrainDragOrigin?(origin) ?? origin)
    }
    override func mouseUp(with event:NSEvent) {
        if contextClick { contextClick=false;return }
        onDragEnd?();if !dragged { onClick?() }
    }
    override func rightMouseDown(with event:NSEvent) { dismissHover();onMenu?(event) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance();needsDisplay=true }
    override func draw(_ dirtyRect:NSRect) {
        let style:RingDrawingStyle = effectiveAppearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? .dark:.light
        RingPainter.draw(composition:composition,bounds:bounds,style:style,opaqueBackground:coversNativeUsage)
    }
}
