import UIKit
import Compression

// 与圆屏 TYPE 5 协议一致：RGB565 调色板、四位索引 RLE、zlib 包装。
enum CrossImageEncoder {
    static func encode(_ image: UIImage) -> Data? {
        guard let source = image.cgImage, source.width > 0, source.height > 0 else { return nil }
        let scale = min(1.0, 256.0 / Double(source.width), 160.0 / Double(source.height))
        let w = max(1, Int(Double(source.width) * scale)), h = max(1, Int(Double(source.height) * scale))
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
            ctx.draw(source, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))); return true
        }
        guard ok else { return nil }
        var bins = [Int](repeating: 0, count: 4096)
        for i in stride(from: 0, to: w*h, by: max(1, w*h/5000)) {
            let p = i*4; bins[(Int(pixels[p] >> 4) << 8) | (Int(pixels[p+1] >> 4) << 4) | Int(pixels[p+2] >> 4)] += 1
        }
        let top = bins.indices.filter { bins[$0] > 0 }.sorted { bins[$0] == bins[$1] ? $0 < $1 : bins[$0] > bins[$1] }.prefix(16)
        var palette = [(Int,Int,Int)]()
        for b in top { palette.append((((b >> 8) & 15)*17, ((b >> 4) & 15)*17, (b & 15)*17)) }
        while palette.count < 16 { let v = palette.count * 17; palette.append((v,v,v)) }
        var indices = [UInt8](repeating: 0, count: w*h)
        for i in 0..<(w*h) {
            let p = i*4, r = Int(pixels[p]), g = Int(pixels[p+1]), b = Int(pixels[p+2])
            var best = 0, distance = Int.max
            for j in 0..<16 {
                let c = palette[j], dr = r-c.0, dg = g-c.1, db = b-c.2
                let d = dr*dr*2 + dg*dg*4 + db*db*3
                if d < distance { distance = d; best = j }
            }
            indices[i] = UInt8(best)
        }
        var rle = [UInt8](); rle.reserveCapacity(w*h)
        var i = 0
        while i < indices.count {
            var run = 1
            while i+run < indices.count && run < 271 && indices[i+run] == indices[i] { run += 1 }
            if run <= 15 { rle.append(UInt8((run-1)<<4) | indices[i]) }
            else { rle.append(0xf0 | indices[i]); rle.append(UInt8(run-16)) }
            i += run
        }
        var deflated = [UInt8](repeating: 0, count: rle.count * 2 + 1024)
        let compressedSize = rle.withUnsafeBytes { input in
            deflated.withUnsafeMutableBytes { output in
                compression_encode_buffer(output.bindMemory(to: UInt8.self).baseAddress!, output.count,
                                          input.bindMemory(to: UInt8.self).baseAddress!, input.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard compressedSize > 0 else { return nil }
        // Apple 输出裸 DEFLATE；加 zlib 头和 Adler-32，供圆屏的 miniz 解码。
        var result = Data()
        func word(_ n: Int) { result.append(UInt8(n & 255)); result.append(UInt8((n >> 8) & 255)) }
        word(w); word(h); word(0xa000)
        for c in palette { word(((c.0 >> 3) << 11) | ((c.1 >> 2) << 5) | (c.2 >> 3)) }
        let n = rle.count
        for shift in stride(from: 0, to: 32, by: 8) { result.append(UInt8((n >> shift) & 255)) }
        result.append(contentsOf: [0x78,0x9c]); result.append(contentsOf: deflated.prefix(compressedSize))
        var a: UInt32 = 1, b: UInt32 = 0
        for v in rle { a = (a + UInt32(v)) % 65521; b = (b + a) % 65521 }
        let checksum = (b << 16) | a
        for shift in stride(from: 24, through: 0, by: -8) { result.append(UInt8((checksum >> shift) & 255)) }
        return result.count <= 65536 ? result : nil
    }
}

/// 版本：跟随 App 版本（见 Config.swift）
///
/// 把中文文字画成 4 位灰度小图片（16 级灰度，两个像素占一个字节，高 4 位是左边那个），发给圆屏显示。
/// 圆屏没有中文字库，用手机的字体画好再发过去（和安卓版格式一样）。
enum TextImage {
    struct Img { let w: Int; let h: Int; let data: Data }

    /// maxW：最大宽度（像素）；文字太长先缩小字号，还放不下就截断加省略号
    static func render(_ text: String, maxW: Int, size: CGFloat, minSize: CGFloat = 16, byteLimit: Int? = nil) -> Img? {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        var fontSize = size
        func attrs(_ s: CGFloat) -> [NSAttributedString.Key: Any] {
            [.font: UIFont.boldSystemFont(ofSize: s), .foregroundColor: UIColor.white]
        }
        func width(_ s: String, _ fs: CGFloat) -> CGFloat { (s as NSString).size(withAttributes: attrs(fs)).width }
        func height(_ fs:CGFloat)->Int {min(60,max(1,Int(ceil(UIFont.boldSystemFont(ofSize:fs).lineHeight))))}
        func limit(_ fs:CGFloat)->Int {
            byteLimit.map{TextBitmapBudget.width(maximum:maxW,height:height(fs),bytes:$0)} ?? maxW
        }
        while width(t, fontSize) > CGFloat(limit(fontSize)) && fontSize > minSize { fontSize -= 1 }
        let allowed=limit(fontSize)
        guard allowed>0 else {return nil}
        if width(t, fontSize) > CGFloat(allowed) {
            while t.count > 1 && width(t + "…", fontSize) > CGFloat(allowed) { t.removeLast() }
            t += "…"
        }
        guard width(t,fontSize)<=CGFloat(allowed) else {return nil}
        let font = UIFont.boldSystemFont(ofSize: fontSize)
        let h = min(60, max(1, Int(ceil(font.lineHeight))))
        let w = min(allowed, max(1, Int(ceil(width(t, fontSize)))))

        // 灰度画布：黑底白字，灰度值就是“浓淡”
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h))            // UIKit 的坐标是从上往下
        ctx.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(ctx)
        (t as NSString).draw(at: .zero, withAttributes: attrs(fontSize))
        UIGraphicsPopContext()
        guard let buf = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }

        let bpr = (w + 1) / 2
        var out = [UInt8](repeating: 0, count: bpr * h)
        for y in 0..<h {
            for x in 0..<w {
                let a = Int(buf[y * w + x])
                let nib = min(15, (a + 8) / 17)
                if nib == 0 { continue }
                let i = y * bpr + (x >> 1)
                out[i] |= (x & 1 == 0) ? UInt8(nib << 4) : UInt8(nib)
            }
        }
        return Img(w: w, h: h, data: Data(out))
    }

    /// 画好直接发到圆屏某一栏；文字为空就清掉那一栏
    static func send(slot: Int, _ text: String, maxW: Int, size: CGFloat, minSize: CGFloat) {
        if let img = render(text, maxW: maxW, size: size, minSize: minSize) {
            BleLink.shared.sendImage(slot: slot, w: img.w, h: img.h, data: img.data)
        } else {
            BleLink.shared.sendImage(slot: slot, w: 0, h: 0, data: Data())
        }
    }
}
