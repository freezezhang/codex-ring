import XCTest
import AppKit
import QuotaCore
import RingDrawing
final class RingDrawingTests:XCTestCase {
    func composition(used:Double,metric:DisplayMetric,dual:Bool=false)->RingComposition {
        let now=Date();var p=RingPreferences();p.metric=metric;p.showFiveHours=dual
        let q=[WeeklyQuota(id:"codex/secondary",label:"codex",remaining:100-used,resetsAt:now.addingTimeInterval(3600)),
               WeeklyQuota(id:"codex/primary",label:"codex",remaining:30,resetsAt:now.addingTimeInterval(3600),period:.fiveHours)]
        return RingComposition(snapshot:QuotaSnapshot(source:.official,fetchedAt:now,quotas:q),preferences:p,fiveHourSupport:dual)
    }
    func render(_ c:RingComposition,size:Int=26,style:RingDrawingStyle = .dark)throws->NSBitmapImageRep {
        let rep=try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size*2,pixelsHigh:size*2,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        let context=try XCTUnwrap(NSGraphicsContext(bitmapImageRep:rep))
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=context
        context.cgContext.scaleBy(x:2,y:2);RingPainter.draw(composition:c,bounds:NSRect(x:0,y:0,width:size,height:size),style:style)
        context.flushGraphics();NSGraphicsContext.restoreGraphicsState();return rep
    }
    func color(_ rep:NSBitmapImageRep,_ x:Int,_ y:Int)->NSColor { rep.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB) ?? .clear }
    func hasBlue(_ rep:NSBitmapImageRep,x:Int,y:Int)->Bool {
        for xx in (x-1)...(x+1) { for yy in (y-1)...(y+1) { let c=color(rep,xx,yy);if c.blueComponent-c.redComponent>0.2 { return true } } };return false
    }
    func testAvatarRasterDistinguishesClockwiseAndCounterclockwise() throws {
        let used=try render(composition(used:32,metric:.used)),remaining=try render(composition(used:32,metric:.remaining))
        XCTAssertTrue(hasBlue(used,x:47,y:26));XCTAssertFalse(hasBlue(used,x:5,y:26))
        XCTAssertTrue(hasBlue(remaining,x:5,y:26));XCTAssertFalse(hasBlue(remaining,x:47,y:26))
    }
    func testZeroAndFullRingsRenderWithoutFakeUnknowns() throws {
        let zero=try render(composition(used:0,metric:.used)),full=try render(composition(used:0,metric:.remaining))
        XCTAssertFalse(hasBlue(zero,x:47,y:26));XCTAssertTrue(hasBlue(full,x:47,y:26));XCTAssertTrue(hasBlue(full,x:5,y:26))
        XCTAssertEqual(composition(used:0,metric:.used).outer.compactText,"0")
        XCTAssertEqual(composition(used:0,metric:.remaining).outer.compactText,"100")
    }
    func testDoubleRingSmallRasterHasIndependentColorsAndReadableCenter() throws {
        let rep=try render(composition(used:92,metric:.used,dual:true))
        var red=0,yellow=0,white=0
        for x in 0..<52 { for y in 0..<52 { let c=color(rep,x,y)
            if c.redComponent>0.6 && c.redComponent-c.greenComponent>0.2 { red += 1 }
            if c.redComponent>0.6 && c.greenComponent>0.55 && c.blueComponent<0.6 { yellow += 1 }
            if (17..<35).contains(x) && (17..<35).contains(y) && min(c.redComponent,c.greenComponent,c.blueComponent)>0.8 { white += 1 }
        } }
        XCTAssertGreaterThan(red,8);XCTAssertGreaterThan(yellow,8);XCTAssertGreaterThan(white,8)
        XCTAssertLessThan(color(rep,0,0).alphaComponent,0.1)
    }
    func testEverySizeAndMetricRendersZeroHundredAndDoubleRing() throws {
        for style in [RingDrawingStyle.light,.dark] { for size in RingSize.allCases { for metric in DisplayMetric.allCases { for value in [0.0,100] {
            let rep=try render(composition(used:value,metric:metric,dual:true),size:size.rawValue,style:style)
            XCTAssertEqual(rep.pixelsWide,size.rawValue*2);XCTAssertGreaterThan(color(rep,rep.pixelsWide/2,rep.pixelsHigh/2).alphaComponent,0.9)
        } } } }
    }
    func testBothThemesKeepOppositeDirectionsAndTransparentCorners() throws {
        for style in [RingDrawingStyle.light,.dark] {
            let u=try render(composition(used:32,metric:.used),style:style)
            let r=try render(composition(used:32,metric:.remaining),style:style)
            XCTAssertTrue(hasBlue(u,x:47,y:26));XCTAssertFalse(hasBlue(u,x:5,y:26))
            XCTAssertTrue(hasBlue(r,x:5,y:26));XCTAssertFalse(hasBlue(r,x:47,y:26))
            XCTAssertLessThan(color(u,0,0).alphaComponent,0.1)
        }
    }
    func testThemeChangesBodyAndKeepsReadableTextContrast() throws {
        let c=composition(used:32,metric:.used)
        for style in [RingDrawingStyle.light,.dark] {
            let rep=try render(c,style:style),background=color(rep,26,37)
            if style == .light { XCTAssertGreaterThan(background.redComponent,0.9) }
            else { XCTAssertLessThan(background.redComponent,0.3) }
            var contrastingTextPixels=0
            for x in 17..<35 { for y in 17..<35 {
                let pixel=color(rep,x,y)
                let difference=abs(pixel.redComponent-background.redComponent)+abs(pixel.greenComponent-background.greenComponent)+abs(pixel.blueComponent-background.blueComponent)
                if difference>1.6 { contrastingTextPixels += 1 }
            } }
            XCTAssertGreaterThan(contrastingTextPixels,8)
        }
        for band in UsageBand.allCases { XCTAssertNotEqual(band.color(for:.light),band.color(for:.dark)) }
    }
}
