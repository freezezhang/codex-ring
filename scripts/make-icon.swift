import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// The approved image is the source of truth; do not redraw or reinterpret its design.
let output=URL(fileURLWithPath:CommandLine.arguments.dropFirst().first ?? "assets",isDirectory:true)
let sourceURL=output.appendingPathComponent("AppIcon-source.png")
let iconset=output.appendingPathComponent("AppIcon.iconset",isDirectory:true)
enum IconError:Error { case invalidSource,thumbnail(Int),write(URL) }
guard let source=CGImageSourceCreateWithURL(sourceURL as CFURL,nil),
      let original=CGImageSourceCreateImageAtIndex(source,0,nil),
      original.width == original.height,original.width>=1024 else { throw IconError.invalidSource }
try FileManager.default.createDirectory(at:iconset,withIntermediateDirectories:true)
func writePNG(size:Int,to url:URL)throws {
    let options:[CFString:Any]=[
        kCGImageSourceCreateThumbnailFromImageAlways:true,
        kCGImageSourceCreateThumbnailWithTransform:true,
        kCGImageSourceThumbnailMaxPixelSize:size
    ]
    guard let image=CGImageSourceCreateThumbnailAtIndex(source,0,options as CFDictionary),
          image.width == size,image.height == size else { throw IconError.thumbnail(size) }
    guard let destination=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil) else { throw IconError.write(url) }
    CGImageDestinationAddImage(destination,image,nil)
    guard CGImageDestinationFinalize(destination) else { throw IconError.write(url) }
}
for points in [16,32,128,256,512] {
    for scale in [1,2] {
        let name="icon_\(points)x\(points)\(scale == 2 ? "@2x":"").png"
        try writePNG(size:points*scale,to:iconset.appendingPathComponent(name))
    }
}
try writePNG(size:1024,to:output.appendingPathComponent("AppIcon.png"))
print("Converted approved CodexRing icon: 16–1024 px, original alpha preserved.")
