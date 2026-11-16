import AppKit
import QuotaCore

/// A nonactivating hover card works even while Codex is the active application.
/// It never intercepts the mouse or changes keyboard focus.
final class RingHoverTip {
    private let panel:NSPanel
    private let label=NSTextField(wrappingLabelWithString:"")
    init() {
        panel=NSPanel(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.isOpaque=false;panel.backgroundColor = .clear;panel.hasShadow=true
        panel.hidesOnDeactivate=false;panel.ignoresMouseEvents=true;panel.isReleasedWhenClosed=false
        panel.level = .statusBar
        panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.canJoinAllApplications,.ignoresCycle]
        panel.animationBehavior = .none
        let material=NSVisualEffectView(frame:.zero)
        material.material = .popover;material.blendingMode = .behindWindow;material.state = .active
        material.wantsLayer=true;material.layer?.cornerRadius=9;material.layer?.masksToBounds=true
        label.font = .systemFont(ofSize:12);label.textColor = .labelColor
        label.maximumNumberOfLines=0;label.isSelectable=false
        material.addSubview(label);panel.contentView=material
    }
    var isVisible:Bool { panel.isVisible }
    func show(text:String,beside owner:NSWindow) {
        guard !text.isEmpty,owner.isVisible,owner.isOnActiveSpace else { hide();return }
        panel.title=L10n.string("hover.windowTitle")
        let screen=owner.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? owner.frame
        let paragraph=NSMutableParagraphStyle();paragraph.lineSpacing=4
        let styled=NSMutableAttributedString(string:text,attributes:[.font:NSFont.systemFont(ofSize:12),.foregroundColor:NSColor.labelColor,.paragraphStyle:paragraph])
        let datePattern=try! NSRegularExpression(pattern:#"\d{4}[.-]\d{2}[.-]\d{2} \d{2}:\d{2}"#)
        for match in datePattern.matches(in:text,range:NSRange(location:0,length:(text as NSString).length)) {
            styled.addAttribute(.font,value:NSFont.monospacedSystemFont(ofSize:12,weight:.regular),range:match.range)
        }
        let natural=styled.boundingRect(with:NSSize(width:1000,height:CGFloat.greatestFiniteMagnitude),options:[.usesLineFragmentOrigin,.usesFontLeading])
        let width=min(max(120,ceil(natural.width)+26),min(360,max(120,screen.width-24)))
        let measured=styled.boundingRect(with:NSSize(width:width-24,height:CGFloat.greatestFiniteMagnitude),options:[.usesLineFragmentOrigin,.usesFontLeading])
        let height=min(ceil(measured.height)+24,screen.height-16)
        var x=owner.frame.maxX+8
        if x+width>screen.maxX { x=owner.frame.minX-width-8 }
        x=max(screen.minX+8,min(x,screen.maxX-width-8))
        let y=max(screen.minY+8,min(owner.frame.midY-height/2,screen.maxY-height-8))
        panel.appearance=owner.effectiveAppearance
        label.attributedStringValue=styled
        panel.setFrame(NSRect(x:x,y:y,width:width,height:height),display:false)
        label.frame=NSRect(x:12,y:12,width:width-24,height:height-24)
        panel.orderFrontRegardless()
    }
    func hide() { panel.orderOut(nil) }
}
