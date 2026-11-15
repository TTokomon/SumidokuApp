import AppKit
let output=URL(fileURLWithPath:CommandLine.arguments[1])
let names=["Silent Orbit","Paper Cities","After the Rain","Northbound","The Blue Hour","Small Wonders","Night Market","Last Light"]
let colors:[NSColor]=[.init(srgbRed:0.13,green:0.32,blue:0.36,alpha:1),.init(srgbRed:0.75,green:0.38,blue:0.28,alpha:1),.init(srgbRed:0.30,green:0.40,blue:0.61,alpha:1),.init(srgbRed:0.44,green:0.51,blue:0.36,alpha:1),.init(srgbRed:0.24,green:0.25,blue:0.46,alpha:1),.init(srgbRed:0.70,green:0.51,blue:0.21,alpha:1),.init(srgbRed:0.44,green:0.29,blue:0.40,alpha:1),.init(srgbRed:0.57,green:0.48,blue:0.38,alpha:1)]
_ = NSApplication.shared
for (index,name) in names.enumerated() {
    let image=NSImage(size:NSSize(width:400,height:600));image.lockFocus()
    colors[index].setFill();NSRect(x:0,y:0,width:400,height:600).fill()
    NSColor(white:1,alpha:0.13).setFill();NSBezierPath(ovalIn:NSRect(x:45,y:210,width:310,height:310)).fill()
    NSColor(white:1,alpha:0.28).setFill();NSBezierPath(roundedRect:NSRect(x:90,y:180,width:220,height:290),xRadius:95,yRadius:95).fill()
    NSColor(white:0.98,alpha:0.85).setFill();NSRect(x:50+index*4,y:160,width:300-index*8,height:3).fill()
    let attrs:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:35,weight:.bold),.foregroundColor:NSColor.white]
    for (line,word) in name.uppercased().split(separator:" ").enumerated() { String(word).draw(at:NSPoint(x:30,y:115-line*39),withAttributes:attrs) }
    "ORIGINAL UI FIXTURE  •  VOL. 01".draw(at:NSPoint(x:30,y:555),withAttributes:[.font:NSFont.systemFont(ofSize:12,weight:.medium),.foregroundColor:NSColor.white])
    image.unlockFocus()
    let png=NSBitmapImageRep(data:image.tiffRepresentation!)!.representation(using:.png,properties:[:])!
    try png.write(to:output.appendingPathComponent("cover-\(index).png"))
}
let page=NSImage(size:NSSize(width:600,height:850));page.lockFocus();NSColor.white.setFill();NSRect(x:0,y:0,width:600,height:850).fill()
for i in 0..<4 {
    let rect=NSRect(x:25+(i%2)*280,y:30+(i/2)*400,width:270,height:385)
    NSColor(white:0.97,alpha:1).setFill();rect.fill();NSColor.black.setStroke();let border=NSBezierPath(rect:rect);border.lineWidth=3;border.stroke()
    NSColor(white:0.3+Double(i)*0.12,alpha:1).setFill();NSBezierPath(ovalIn:NSRect(x:rect.minX+40,y:rect.minY+90,width:170,height:170)).fill()
    "The next chapter…".draw(in:NSRect(x:rect.minX+18,y:rect.maxY-65,width:220,height:40),withAttributes:[.font:NSFont.systemFont(ofSize:19,weight:.medium),.foregroundColor:NSColor.black])
}
page.unlockFocus();try NSBitmapImageRep(data:page.tiffRepresentation!)!.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("page.png"))
