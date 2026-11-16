import AppKit
import QuotaCore

public extension UsageBand {
    var color:NSColor { NSColor(calibratedRed:CGFloat((hex>>16)&255)/255,green:CGFloat((hex>>8)&255)/255,blue:CGFloat(hex&255)/255,alpha:1) }
    func color(for style:RingDrawingStyle)->NSColor {
        if style == .dark { return color }
        let value:UInt32
        switch self { case .normal:value=0x2678B8;case .yellow:value=0xA87900;case .orange:value=0xC56816;case .red:value=0xC44252 }
        return NSColor(calibratedRed:CGFloat((value>>16)&255)/255,green:CGFloat((value>>8)&255)/255,blue:CGFloat(value&255)/255,alpha:1)
    }
}
public enum RingDrawingStyle { case light,dark }
public enum RingPainter {
    public static func draw(composition:RingComposition?,bounds:NSRect,style:RingDrawingStyle = .dark,opaqueBackground:Bool = false) {
        let diameter=bounds.width,center=NSPoint(x:bounds.midX,y:bounds.midY)
        let body=NSBezierPath(ovalIn:bounds.insetBy(dx:0.7,dy:0.7))
        let dark=style == .dark
        let background=dark ? NSColor(calibratedRed:0.12,green:0.15,blue:0.19,alpha:opaqueBackground ? 1:0.96):NSColor(calibratedWhite:0.97,alpha:opaqueBackground ? 1:0.98)
        let foreground=dark ? NSColor.white:NSColor(calibratedRed:0.12,green:0.16,blue:0.21,alpha:1)
        background.setFill();body.fill()
        (dark ? NSColor.white.withAlphaComponent(0.14):NSColor.black.withAlphaComponent(0.12)).setStroke();body.lineWidth=0.7;body.stroke()
        let compact=diameter<=32,dual=composition?.inner != nil
        let width:CGFloat = compact ? (dual ? 1.25:2):(dual ? 2:max(2.6,diameter*0.048))
        let radius=diameter/2 - (compact ? 2.3:4.5)
        paintRing(composition?.outer,center:center,radius:radius,width:width,style:style)
        if let inner=composition?.inner { paintRing(inner,center:center,radius:radius-width-(compact ? 1.1:2),width:width,style:style) }
        let primary=composition?.center
        let title=compact ? primary?.compactText ?? "—":primary?.text ?? "—"
        let fontSize:CGFloat
        if compact { fontSize = dual ? max(8.5,diameter*(title.count>2 ? 0.32:0.4)):max(10,diameter*(title.count>2 ? 0.38:0.48)) }
        else { fontSize=diameter*(dual ? 0.26:title.count>4 ? 0.245:0.29) }
        let attributes:[NSAttributedString.Key:Any]=[.font:NSFont.monospacedDigitSystemFont(ofSize:fontSize,weight:.semibold),.foregroundColor:foreground]
        let textSize=title.size(withAttributes:attributes)
        title.draw(at:NSPoint(x:center.x-textSize.width/2,y:center.y-textSize.height/2+(compact ? 0:4)),withAttributes:attributes)
        guard !compact else { return }
        let caption:String
        if primary?.display.source == .debug { caption="调试" }
        else if let primary,primary.display.status == .available,dual { caption=(composition?.centerPeriod == .fiveHours ? "5h":"周")+primary.metric.shortTitle }
        else if let primary,primary.display.status == .available,composition?.outerPeriod == .fiveHours { caption="5h"+primary.metric.shortTitle }
        else { caption=primary?.caption ?? "未连接" }
        let sub:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:max(8,diameter*0.13),weight:.medium),.foregroundColor:foreground.withAlphaComponent(0.68)]
        let size=caption.size(withAttributes:sub)
        caption.draw(at:NSPoint(x:center.x-size.width/2,y:center.y-diameter*0.29),withAttributes:sub)
    }
    private static func paintRing(_ presentation:RingPresentation?,center:NSPoint,radius:CGFloat,width:CGFloat,style:RingDrawingStyle) {
        let rect=NSRect(x:center.x-radius,y:center.y-radius,width:radius*2,height:radius*2)
        let track=NSBezierPath(ovalIn:rect);track.lineWidth=width
        (style == .dark ? NSColor.white:NSColor.black).withAlphaComponent(0.10).setStroke();track.stroke()
        guard let presentation,let value=presentation.value,value>0 else { return }
        let arc=NSBezierPath();arc.lineWidth=width;arc.lineCapStyle = .round
        if value>=100 { arc.appendOval(in:rect) }
        else { arc.appendArc(withCenter:center,radius:radius,startAngle:90,endAngle:presentation.arcEndAngle ?? 90,clockwise:presentation.clockwise) }
        (presentation.band?.color(for:style) ?? .secondaryLabelColor).setStroke();arc.stroke()
    }
}
