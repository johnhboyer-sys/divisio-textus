import Foundation
import CoreGraphics
enum PageClassification { case spread, single }
enum CropTarget { case text, page }
struct Image {
 let w: Int; let h: Int; var p: [UInt8]
 init(_ w:Int = 520, _ h:Int = 800) { self.w=w; self.h=h; p=Array(repeating:255,count:w*h) }
 mutating func box(_ x:Int,_ y:Int,_ w:Int,_ h:Int,_ v:UInt8=0) {
  for yy in max(0,y)..<min(self.h,y+h) { for xx in max(0,x)..<min(self.w,x+w) { p[yy*self.w+xx]=v } }
 }
 mutating func body(_ x0:Int=150,_ x1:Int=450) {
  for y in stride(from:100,to:700,by:20) { for x in stride(from:x0,to:x1-8,by:14) { box(x,y,min(10,x1-x),8,25) } }
 }
 func show(_ name:String) {
  let r=PageAnalyzer.contentBounds(GrayBuffer(width:w,height:h,pixels:p), xRange:0..<1)
  print(name, "crop(px):",r.crop.minX*Double(w),r.crop.minY*Double(h),r.crop.maxX*Double(w),r.crop.maxY*Double(h), "blank",r.blank)
 }
}
var a=Image(); a.body(); a.box(80,18,8,10); a.box(92,18,8,10); a.show("outside running head")
var b=Image(); b.body(300,460); b.box(250,778,8,10); b.box(262,778,8,10); b.show("centered folio offset body")
var c=Image(); c.body(); for y in stride(from:60,to:760,by:70) { c.box(8,y,22,8) }; c.show("printed margin dashes")
var d=Image(); d.body(); for y in 40..<760 { d.box(0,y,25+40*y/800,1) }; d.show("slanted dark plate")
var e=Image(); e.body(); e.box(480,0,40,800,140); for x in stride(from:450,through:510,by:5) { e.box(x,300,2,40); e.box(x,400,2,8) }; e.show("heading plus short strokes on shadow")
var f=Image(); f.body(); for y in 72..<728 { f.box(10,y,60+35*y/800-10,1) }; f.show("tall inset tapered illustration")
var g=Image(); g.body(); for y in 100..<260 { g.box(0,y,2+(y-100)/8,1) }; g.show("pointed illustration inside page")
var h=Image(); h.body(); h.box(480,0,40,800,140); for x in stride(from:450,through:510,by:5) { h.box(x,300,2,40) }; h.show("single heading shadow control")
print("-- variants --")
for x in [0, 4, 8, 10, 12] {
 var a=Image(); a.body(); a.box(x,18,8,10); a.box(x+12,18,8,10); a.show("tight head x=\(x)")
}
for ht in [2,3,4,5] {
 var a=Image(); a.body(300,460); a.box(250,778,8,ht); a.box(262,778,8,ht); a.show("folio height \(ht)")
}
var u=Image(); u.body(); u.box(80,18,8,10); u.box(92,18,8,10); u.box(80,30,360,2); u.show("underlined head")
var rule=Image(); rule.body(); rule.box(80,18,360,2); rule.show("printed running rule")
for ht in [8,16,20,24] {
 var a=Image(1040,800); a.body(670,970)
 for y in stride(from:60,to:760,by:70) { a.box(528,y,22,ht) }
 let r=PageAnalyzer.contentBounds(GrayBuffer(width:a.w,height:a.h,pixels:a.p),xRange:0.5..<1)
 print("gutter dashes height",ht,"crop px",r.crop.minX*1040,r.crop.minY*800,r.crop.maxX*1040,r.crop.maxY*800)
}
var roman=Image(1040,800); roman.body(670,970)
for y in stride(from:60,to:760,by:70) { roman.box(532,y,4,16) }
let rr=PageAnalyzer.contentBounds(GrayBuffer(width:roman.w,height:roman.h,pixels:roman.p),xRange:0.5..<1)
print("gutter Roman I",rr)
for top in [0,10,30,40,41,60,72] {
 var a=Image(); a.body(); for y in top..<800 { a.box(10,y,50+35*y/800,1) }; a.show("bleed slanted top \(top)")
}
for noiseH in [0,1,2,3] {
 var a=Image(); a.body(); a.box(480,0,40,800,140)
 for x in stride(from:450,through:510,by:5) { a.box(x,300,2,40); a.box(x,400,2,8); if noiseH>0 { a.box(x,450,2,noiseH) } }
 a.show("shadow heading noise height \(noiseH)")
}
for x in [0,4,8,10,12,80] {
 var a=Image(); a.body(); a.box(x,18,8,10); a.show("single tight head x=\(x)")
}
for x in [0,10,16,20] {
 var a=Image(); a.body(); for y in 100..<260 { a.box(x,y,2+(y-100)/8,1) }; a.show("pointed inside picture x=\(x)")
}
for height in [500,600,700] {
 var a=Image(); a.body(); for y in 50..<(50+height) { a.box(100,y,2,1) }; a.show("printed vertical rule height=\(height)")
}
var inner=Image(800,800); inner.body(550,750)
for y in stride(from:60,to:760,by:70) { inner.box(408,y,22,16) }
let ir=PageAnalyzer.contentBounds(GrayBuffer(width:800,height:800,pixels:inner.p),xRange:0.5..<1)
print("800 gutter blocks",ir.crop.minX*800,ir.crop.minY*800,ir.crop.maxX*800,ir.crop.maxY*800)
var ii=Image(800,800); ii.body(550,750)
for y in stride(from:60,to:760,by:70) { ii.box(410,y,4,16) }
let iir=PageAnalyzer.contentBounds(GrayBuffer(width:800,height:800,pixels:ii.p),xRange:0.5..<1)
print("800 gutter I",iir.crop.minX*800,iir.crop.minY*800,iir.crop.maxX*800,iir.crop.maxY*800)
import CoreText
for pt in [5.0,6.0,7.0,8.0] {
 let ctx=CGContext(data:nil,width:520,height:800,bitsPerComponent:8,bytesPerRow:520,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue)!
 ctx.setFillColor(gray:1,alpha:1);ctx.fill(CGRect(x:0,y:0,width:520,height:800))
 let font=CTFontCreateWithName("Times-Roman" as CFString,pt*110/72*800/1210,nil)
 let str=NSAttributedString(string:"iv",attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(gray:0,alpha:1)])
 ctx.textPosition=CGPoint(x:250,y:20); CTLineDraw(CTLineCreateWithAttributedString(str),ctx)
 let g=GrayBuffer(cgImage:ctx.makeImage()!)!
 let ys=(0..<800).filter { y in (0..<520).contains { g.value($0,y)<185 } }
 let xs=(0..<520).filter { x in (0..<800).contains { g.value(x,$0)<185 } }
 var a=Image();a.body(300,460)
 for y in 0..<800 { for x in 0..<520 where g.value(x,y)<255 { a.p[y*520+x]=g.value(x,y) } }
 if pt == 6 { for y in ys { print("folio dark row",y,(0..<520).filter {g.value($0,y)<185}) } }; print("font folio point",pt,"ink xs",xs.min() ?? -1,xs.max() ?? -1,"ys",ys.min() ?? -1,ys.max() ?? -1)
 a.show("real roman folio \(pt)pt at110dpi downsampled")
}

// New adversarial cases for the current diff.
extension Image {
 mutating func glyph(_ text:String, _ x:Int, _ y:Int, _ pt:Double) {
  let ctx=CGContext(data:nil,width:400,height:100,bitsPerComponent:8,bytesPerRow:400,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue)!
  ctx.setFillColor(gray:1,alpha:1);ctx.fill(CGRect(x:0,y:0,width:400,height:100))
  let font=CTFontCreateWithName("Times-Roman" as CFString,pt*110/72*800/1210,nil)
  let str=NSAttributedString(string:text,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(gray:0,alpha:1)])
  ctx.textPosition=CGPoint(x:10,y:30); CTLineDraw(CTLineCreateWithAttributedString(str),ctx)
  let g=GrayBuffer(cgImage:ctx.makeImage()!)!
  let xs=(0..<400).filter { xx in (0..<100).contains { g.value(xx,$0)<191 } }
  let ys=(0..<100).filter { yy in (0..<400).contains { g.value($0,yy)<191 } }
  guard let x0=xs.min(),let y0=ys.min(),let x1=xs.max(),let y1=ys.max() else {return}
  for yy in y0...y1 {for xx in x0...x1 { let dx=x+xx-x0,dy=y+yy-y0; if dx>=0 && dx<w && dy>=0 && dy<h { p[dy*w+dx]=min(p[dy*w+dx],g.value(xx,yy)) } }}
 }
 func showRange(_ name:String,_ range:Range<Double>) {
  let r=PageAnalyzer.contentBounds(GrayBuffer(width:w,height:h,pixels:p),xRange:range)
  print(name,"crop(px):",r.crop.minX*Double(w),r.crop.minY*Double(h),r.crop.maxX*Double(w),r.crop.maxY*Double(h),"blank",r.blank)
 }
}
for pt in [5.0,6.0,7.0,8.0,10.0,12.0] {
 for text in ["iv","viii","123","HISTORY"] {
  for y in [0,1,4,5,10,18,24,28,32,770,780,790,796] {
   var a=Image(); a.body(300,460); a.glyph(text,250,y,pt)
   a.show("glyph \(text) \(pt)pt y=\(y)")
  }
 }
}
for pt in [8.0,12.0,16.0] {
 for text in ["HISTORY","123"] {
  for y in [0,4,18,24,28,32,40,770,780] {
   for x in [0,1,4,490,510] {
    var a=Image(); a.body(); a.glyph(text,x,y,pt)
    a.show("edge glyph \(text) \(pt)pt x=\(x) y=\(y)")
   }
  }
 }
}
for ruleX in [400,402,406,410,420] {
 for ht in [8,16,20,24] {
  var a=Image(800,800); a.body(550,750); a.box(ruleX,40,1,720)
  for y in stride(from:60,to:760,by:70) {a.box(408,y,22,ht)}
  a.showRange("inner printed dashes ruleX=\(ruleX) height=\(ht)",0.5..<1)
 }
}
for ruleX in [400,402,406,410,420] {
 for text in ["I","II","III","111","123","425a"] {
  for pt in [8.0,12.0,16.0,24.0] {
   var a=Image(800,800);a.body(550,750);a.box(ruleX,40,1,720)
   for y in stride(from:60,to:760,by:70) {a.glyph(text,408,y,pt)}
   a.showRange("inner glyph \(text) \(pt)pt ruleX=\(ruleX)",0.5..<1)
  }
 }
}
for pt in [5.0,6.0,7.0,8.0] {
 for text in ["iv","viii","123"] {
  for y in [0,1,2,3,4,794,795,796,797] {
   var a=Image(); a.body(300,460);a.glyph(text,320,y,pt)
   a.show("body aligned folio \(text) \(pt)pt y=\(y)")
  }
 }
}
// 1. Printed marginal bars beside a printed vertical rule.
var bars=Image(800,800); bars.body(550,750); bars.box(410,40,1,720)
for y in stride(from:60,to:760,by:70) { bars.box(408,y,22,16) }
bars.showRange("printed bars plus rule",0.5..<1)

// 2. Running head touching the scan's left edge.
var head=Image(); head.body(); head.glyph("HISTORY",0,18,12)
head.show("running head at left edge")

// 3. Small folio on the scan's first row, within the body columns.
var folio=Image(); folio.body(300,460); folio.glyph("123",320,0,6)
folio.show("real 6pt folio at top")

// 4. Real marginal numerals beside a vertical rule.
var nums=Image(800,800); nums.body(550,750); nums.box(420,40,1,720)
for y in stride(from:60,to:760,by:70) { nums.glyph("123",408,y,12) }
nums.showRange("real numbers beside rule",0.5..<1)

// Orchestrator's realistic cases (2026-10-19).
var c1=Image(); c1.body(); c1.glyph("THE CHEMISTRY OF COHESION",180,6,9); c1.box(150,22,290,1); c1.show("C1 running head over rule near top")
var c2=Image(); c2.body(); c2.glyph("154",150,2,9); c2.glyph("Chapter Two",260,2,9); c2.show("C2 running head on first rows")
var c3=Image(); c3.body(); c3.box(150,705,100,1); c3.glyph("1 See Aristotle, Meteor. 4.",150,712,7); c3.show("C3 footnote rule and note")
var c4=Image(); c4.body(); c4.box(130,80,330,2); c4.box(130,718,330,2); c4.box(130,80,2,640); c4.box(458,80,2,640); c4.show("C4 printed frame round text")
var c5=Image(); c5.body(); c5.box(120,4,340,2); c5.box(120,792,340,2); c5.show("C5 frame rules near scan top and foot")
var c6=Image(); c6.body(); c6.glyph("— 12 —",270,786,9); c6.show("C6 dashed folio on last rows")
var c7=Image(); c7.body(); c7.box(0,0,40,800,20); c7.glyph("METAPHYSICS",46,20,9); c7.show("C7 running head beside black bed")
var c8=Image(); c8.body(); c8.box(0,0,40,800,20); c8.glyph("82",46,780,9); c8.show("C8 folio beside black bed at foot")
var c9=Image(1040,800); c9.body(560,1000); c9.box(520,0,14,800,60); c9.glyph("1094a",536,120,8); c9.glyph("5",536,220,8); c9.glyph("10",536,320,8); c9.showRange("C9 Bekker numbers beside gutter shadow",0.5..<1)
var c10=Image(); c10.body(150,290); c10.body(310,450); c10.box(299,90,1,610); c10.show("C10 two columns with rule")
var c11=Image(); c11.body(); for y in 0..<200 { c11.box(300+y/4,y,140-y/4,1,40) }; c11.show("C11 picture bleeding off top at slant")
var c12=Image(); c12.body(); c12.glyph("CHAPTER ONE",200,30,14); c12.box(150,52,290,1); c12.show("C12 underlined chapter head")
var c13=Image(); c13.body(); c13.box(150,2,290,2); c13.show("C13 bare head rule on row 2")
var c14=Image(); c14.body(); c14.glyph("W",150,92,40); c14.show("C14 drop cap at body top")

// Grok's proposed cases (2026-10-19), one statement per line.
var s1=Image(); s1.box(22,200,1,300); s1.glyph("PREFACE",64,2,12); s1.body(260,480); s1.show("S1 running head past a book-block streak")
var s2=Image(); s2.box(22,200,1,300); s2.body(260,480); s2.glyph("quod",64,778,10); s2.show("S2 catchword past a book-block streak")
var s3=Image(); s3.body(60,340); s3.box(470,772,8,12); s3.box(480,772,8,12); s3.box(489,0,31,800); s3.show("S3 foot folio against the bed")
var s4=Image(); s4.box(0,0,34,800); s4.box(36,4,8,12); s4.box(46,4,8,12); s4.box(56,4,8,12); s4.box(66,4,8,12); s4.box(76,4,6,12); s4.body(200,470); s4.show("S4 running head against the bed")
var s5=Image(); s5.box(0,0,34,800); s5.box(36,4,100,2); s5.box(36,24,100,2); s5.box(36,4,2,22); s5.box(134,4,2,22); s5.body(200,470); s5.show("S5 corner frame against the bed")
var s6=Image(); s6.box(0,0,34,800); s6.box(36,4,70,12); s6.box(36,24,420,1); s6.body(200,450); s6.show("S6 marginal head and rule against the bed")
var s7=Image(); s7.body(280,480); for x in stride(from:20,to:160,by:9) { s7.box(x,10,8,3) }; s7.show("S7 dotted head rule in the margin")
var s8=Image(); s8.body(280,480); for x in stride(from:20,to:160,by:9) { s8.box(x,770,8,3) }; s8.show("S8 dotted foot rule in the margin")
var s9=Image(); s9.body(200,480); for y in 0..<760 { s9.box(0,y,12+y/10,1) }; s9.show("S9 slanted plate off the top")
var s10=Image(); s10.body(40,400); for y in 50..<800 { let w=16+(y-50)/10; s10.box(520-w,y,w,1) }; s10.show("S10 slanted plate off the bottom")
var s11=Image(); s11.body(150,470); for y in 50..<750 { s11.box(36+(y-50)*28/700,y,2,1) }; s11.show("S11 diagonal rule in a figure")
var s12=Image(1040,800); s12.body(700,980); for y in 40..<760 { s12.box(536+(y-40)*24/720,y,1,1) }; s12.showRange("S12 slanted inner rule",0.5..<1.0)
var s13=Image(1040,800); s13.body(700,980); s13.box(512,0,6,800); for y in stride(from:40,to:750,by:70) { s13.box(528,y,22,22) }; s13.showRange("S13 bekker blocks beside the fold",0.5..<1.0)
var s14=Image(1040,800); s14.body(720,980); s14.box(522,0,3,800); for y in stride(from:36,to:740,by:68) { s14.box(527,y,22,20) }; s14.showRange("S14 paragraph marks beside a 3px rule",0.5..<1.0)
var s15=Image(1040,800); s15.body(700,980); for y in stride(from:100,to:700,by:20) { s15.box(508,y,10,8) }; for y in stride(from:40,to:750,by:70) { s15.box(528,y,22,22) }; s15.showRange("S15 inner marks beside facing text",0.5..<1.0)
var s16=Image(1040,800); s16.box(520,0,30,800); for x in 550..<560 { s16.box(x,0,1,72) }; s16.box(560,300,3,80); s16.body(700,980); s16.showRange("S16 brace in a ragged gutter shadow",0.5..<1.0)

// Grok round-5 cases (2026-10-19).
do {
 var t=Image()
 t.box(0,0,36,800)
 t.box(36,180,12,250)
 t.body(150,470)
 t.show("G1")
}
do {
 var t=Image()
 t.box(0,0,24,800)
 t.box(24,0,1,260,140)
 t.box(25,0,1,230,140)
 t.box(26,0,1,210,140)
 t.box(27,0,6,220)
 t.body(150,470)
 t.show("G2")
}
do {
 var t=Image()
 t.body(40,420)
 t.box(468,200,14,230)
 t.box(482,0,38,800)
 t.show("G3")
}
do {
 var t=Image()
 t.box(0,0,40,800)
 t.box(40,4,130,18)
 t.body(220,470)
 t.show("G4")
}
do {
 var t=Image()
 t.box(0,0,40,800)
 t.box(48,6,7,12)
 t.box(58,6,7,12)
 t.box(68,6,7,12)
 t.box(78,6,7,12)
 t.box(40,22,80,2)
 t.body(220,470)
 t.show("G5")
}
do {
 var t=Image()
 t.body(40,320)
 t.box(360,772,126,16)
 t.box(486,0,34,800)
 t.show("G6")
}
do {
 var t=Image()
 t.body(200,470)
 t.box(60,0,132,3)
 t.show("G7")
}
do {
 var t=Image()
 t.body(60,300)
 t.box(303,797,140,3)
 t.show("G8")
}
do {
 var t=Image()
 t.box(16,8,10,16)
 t.box(40,100,2,600)
 t.body(180,460)
 t.show("G9")
}
do {
 var t=Image()
 t.body(80,360)
 t.box(400,100,2,600)
 t.box(430,772,18,16)
 t.show("G10")
}
do {
 var t=Image(1040,800)
 t.body(700,980)
 t.box(514,0,6,800)
 for y in [40,110,180,250,320,390,460,530] { t.box(526,y,24,20); t.box(500,y,20,20) }
 t.showRange("G11",0.5..<1.0)
}
do {
 var t=Image(1040,800)
 t.body(50,420)
 t.box(520,0,4,800)
 for y in [30,94,158,222,286,350,414,478] { t.box(478,y,42,36); t.box(520,y,16,36) }
 t.showRange("G12",0.0..<0.5)
}
do {
 var t=Image()
 for i in 0..<33 { t.box(10,20*i,52+i,20) }
 t.body(200,470)
 t.show("G13")
}
do {
 var t=Image()
 t.body(40,380)
 for i in 0..<33 { t.box(458-i,140+20*i,52+i,20) }
 t.show("G14")
}
