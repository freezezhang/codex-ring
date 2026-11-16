import AppKit
import QuartzCore

/// A short, click-through celebration. Separate panels leave ring/Space routing
/// untouched, never take focus, and are completely removed after playback.
final class ResetConfetti {
    private var panels:[NSPanel]=[]
    private var cleanup:DispatchWorkItem?
    func play() {
        guard panels.isEmpty,!NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        for screen in NSScreen.screens {
            let panel=ConfettiPanel(contentRect:screen.frame,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            panel.backgroundColor = .clear;panel.isOpaque=false;panel.hasShadow=false
            panel.ignoresMouseEvents=true;panel.hidesOnDeactivate=false;panel.isReleasedWhenClosed=false
            panel.level = .statusBar
            panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.ignoresCycle,.stationary]
            let view=NSView(frame:NSRect(origin:.zero,size:screen.frame.size));view.wantsLayer=true
            panel.contentView=view
            let colors:[NSColor]=[.systemBlue,.systemPink,.systemYellow,.systemGreen,.systemOrange,.systemPurple]
            // Keep larger displays equally festive, with a bounded layer count.
            let previousCount=min(1200,max(640,Int(screen.frame.width*screen.frame.height/2400)))
            let count=Int((Double(previousCount)*2/3).rounded())
            let startTime=CACurrentMediaTime()
            let columns=Int(ceil(sqrt(Double(count)*screen.frame.width/screen.frame.height)))
            let rows=Int(ceil(Double(count)/Double(columns)))
            for i in 0..<count {
                let piece=CALayer()
                piece.bounds=CGRect(x:0,y:0,width:CGFloat.random(in:6...12),height:CGFloat.random(in:12...24))
                piece.backgroundColor=colors[i%colors.count].cgColor;piece.cornerRadius=1
                // Seed the entire screen, with jitter inside cells to avoid both
                // clumps and a visible grid. Staggered offscreen re-entry keeps
                // the shower full without introducing synchronized waves.
                let start=CGPoint(
                    x:(CGFloat(i%columns)+CGFloat.random(in:0.05...0.95))*screen.frame.width/CGFloat(columns),
                    y:(CGFloat(i/columns)+CGFloat.random(in:0.05...0.95))*screen.frame.height/CGFloat(rows))
                piece.position=start
                piece.opacity=0
                view.layer?.addSublayer(piece)
                let fullDuration=Double.random(in:4...6)
                var delay=Double.random(in:0...0.2)
                let firstDuration=fullDuration*Double((start.y+40)/(screen.frame.height+80))
                Self.addFlight(to:piece,from:start,width:screen.frame.width,duration:firstDuration,
                               beginTime:startTime+delay,key:"fall-0")
                delay += firstDuration+Double.random(in:0.02...0.12)
                var flight=1
                // Re-enter only while emitting; remaining pieces keep falling
                // as they gradually fade, without waiting to reach the bottom.
                while delay<2 {
                    let entry=CGPoint(x:CGFloat.random(in:0...screen.frame.width),y:screen.frame.height+40)
                    let duration=Double.random(in:4...6)
                    Self.addFlight(to:piece,from:entry,width:screen.frame.width,duration:duration,
                                   beginTime:startTime+delay,key:"fall-\(flight)")
                    delay += duration+Double.random(in:0.02...0.12)
                    flight += 1
                }
            }
            panels.append(panel);panel.orderFrontRegardless()
        }
        let work=DispatchWorkItem { [weak self] in self?.dismiss() }
        cleanup=work;DispatchQueue.main.asyncAfter(deadline:.now()+8.5,execute:work)
    }
    private static func addFlight(to piece:CALayer,from start:CGPoint,width:CGFloat,
                                  duration:TimeInterval,beginTime:TimeInterval,key:String) {
        let drift=CGFloat.random(in:-140...140)
        let sway=CGFloat.random(in:25...75)
        let phase=CGFloat.random(in:0...(2 * .pi))
        let turns=CGFloat.random(in:0.8...1.8)
        let travelFraction=CGFloat.random(in:0.65...1)
        let fall=CAKeyframeAnimation(keyPath:"position")
        fall.values=(0...32).map { step in
            let t=CGFloat(step)/32
            let x=start.x+drift*t+sway*(sin(phase+t*turns*2 * .pi)-sin(phase))
            // Always move downward. Do not reflect at the bottom or add upward
            // flutter: both made the previous effect look suspended in the air.
            let y=start.y-(start.y+40)*travelFraction*t
            return NSValue(point:CGPoint(x:reflected(x,limit:width),y:y))
        }
        fall.calculationMode = .linear
        let rotate=CABasicAnimation(keyPath:"transform.rotation.z")
        let angle=Double.random(in:0...(2*Double.pi))
        rotate.fromValue=angle;rotate.toValue=angle+Double.random(in:-14...14)
        let opacity=CAKeyframeAnimation(keyPath:"opacity")
        opacity.values=[0,1,1,0]
        opacity.keyTimes=[0,NSNumber(value:min(0.2,0.06/duration)),NSNumber(value:Double.random(in:0.4...0.55)),1]
        let animation=CAAnimationGroup()
        animation.duration=duration
        for child in [fall,rotate,opacity] { child.duration=duration }
        animation.animations=[fall,rotate,opacity]
        animation.beginTime=beginTime
        piece.add(animation,forKey:key)
    }
    // Reflect gently at the horizontal edges instead of collecting particles at a clamped
    // boundary or sending them across the screen when wrapping coordinates.
    private static func reflected(_ value:CGFloat,limit:CGFloat)->CGFloat {
        let inset:CGFloat=12
        let span=max(1,limit-2*inset)
        let offset=(value-inset).truncatingRemainder(dividingBy:2*span)
        let positive=offset<0 ? offset+2*span:offset
        return inset+(positive>span ? 2*span-positive:positive)
    }
    func dismiss() {
        cleanup?.cancel();cleanup=nil
        for panel in panels { panel.orderOut(nil);panel.close() }
        panels.removeAll()
    }
}
private final class ConfettiPanel:NSPanel {
    override var canBecomeKey:Bool { false }
    override var canBecomeMain:Bool { false }
}
