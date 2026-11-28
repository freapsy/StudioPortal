import AppKit
import Foundation

/// Labelled before/after strip for renders and pictures (agent feedback 17.11.2026): one column per image with
/// title + facts (camera, resolution, samples, source file – from the render's sidecar JSON), optionally extra rows
/// with the same detail crops of every image (collar, sleeve, waist, hem …) at full render resolution.
enum Comparison {
    struct Crop { var name: String; var rect: [Double] }   // x0, y0, x1, y1 as 0–1 from the top left

    static func make(_ p: [String: Any]) throws -> [String: Any] {
        let paths = strings(p["images"] ?? p["_positional"])
        guard (2...8).contains(paths.count) else { throw StudioError.message("Vergleich: 2–8 Bilder angeben (Pfade auf diesem Mac).") }
        let urls = try paths.map { path -> URL in
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else { throw StudioError.message("Bild nicht gefunden: \(path)") }
            return url
        }
        let labels = strings(p["labels"])
        let crops = try parseCrops(p["regions"] ?? p["crops"])
        guard crops.count <= 6 else { throw StudioError.message("Höchstens 6 Ausschnitte.") }

        let images: [(title: String, facts: String, image: CGImage)] = try urls.enumerated().map { index, url in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw StudioError.message("Kein lesbares Bild: \(url.lastPathComponent)") }
            let (title, facts) = describe(url, image: image)
            return (index < labels.count && !labels[index].isEmpty ? labels[index] : title, facts, image)
        }

        let columns = images.count
        let gap: CGFloat = 10, headerHeight: CGFloat = 52, side: CGFloat = crops.isEmpty ? 0 : 120
        let maxWidth: CGFloat = 2400
        let tileWidth = min(800, ((maxWidth - side - gap * CGFloat(columns + 1)) / CGFloat(columns)).rounded())
        let first = images[0].image
        let fullAspect = images.map { CGFloat($0.image.height) / CGFloat(max($0.image.width, 1)) }.max() ?? 1
        var rowHeights = [(tileWidth * fullAspect).rounded()]
        for crop in crops {
            let w = CGFloat(crop.rect[2] - crop.rect[0]) * CGFloat(first.width), h = CGFloat(crop.rect[3] - crop.rect[1]) * CGFloat(first.height)
            rowHeights.append(min(tileWidth * 1.4, (tileWidth * h / max(w, 1)).rounded()))
        }
        let width = Int(side + gap + CGFloat(columns) * (tileWidth + gap))
        let height = Int(headerHeight + gap + rowHeights.reduce(0) { $0 + $1 + gap })

        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw StudioError.message("Vergleich konnte nicht angelegt werden.") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        NSColor(white: 0.08, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let titleStyle: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: NSColor(white: 0.95, alpha: 1)]
        let factStyle: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor(white: 0.65, alpha: 1)]
        let rowStyle: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor(white: 0.85, alpha: 1)]
        let cg = context.cgContext

        func fit(_ text: String, _ style: [NSAttributedString.Key: Any], _ maxWidth: CGFloat) -> NSAttributedString {
            var value = text
            while value.count > 4 && NSAttributedString(string: value, attributes: style).size().width > maxWidth { value = String(value.dropLast(2)) + "…" }
            return NSAttributedString(string: value, attributes: style)
        }
        for (column, item) in images.enumerated() {
            let x = side + gap + CGFloat(column) * (tileWidth + gap)
            let top = CGFloat(height)
            fit(item.title, titleStyle, tileWidth).draw(at: NSPoint(x: x, y: top - 28))
            fit(item.facts, factStyle, tileWidth).draw(at: NSPoint(x: x, y: top - 47))
            var y = top - headerHeight - gap
            for (row, rowHeight) in rowHeights.enumerated() {
                let rect = NSRect(x: x, y: y - rowHeight, width: tileWidth, height: rowHeight)
                var image = item.image
                if row > 0 {
                    let r = crops[row - 1].rect
                    let cropRect = CGRect(x: r[0] * Double(image.width), y: r[1] * Double(image.height),
                                          width: (r[2] - r[0]) * Double(image.width), height: (r[3] - r[1]) * Double(image.height)).integral
                    if let cropped = image.cropping(to: cropRect) { image = cropped }
                }
                let scale = min(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
                let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                cg.draw(image, in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
                if row > 0 && column == 0 {
                    fit(crops[row - 1].name, rowStyle, side - 14).draw(at: NSPoint(x: 10, y: rect.midY - 9))
                }
                if row == 0 && column == 0 && !crops.isEmpty {
                    fit("Ganzes Bild", rowStyle, side - 14).draw(at: NSPoint(x: 10, y: rect.midY - 9))
                }
                y -= rowHeight + gap
            }
        }
        // mark the crop regions on the full images so it is clear where each detail comes from
        if !crops.isEmpty {
            NSColor.systemYellow.withAlphaComponent(0.9).setStroke()
            for (column, item) in images.enumerated() {
                let x = side + gap + CGFloat(column) * (tileWidth + gap)
                let rect = NSRect(x: x, y: CGFloat(height) - headerHeight - gap - rowHeights[0], width: tileWidth, height: rowHeights[0])
                let scale = min(rect.width / CGFloat(item.image.width), rect.height / CGFloat(item.image.height))
                let w = CGFloat(item.image.width) * scale, h = CGFloat(item.image.height) * scale
                let origin = CGPoint(x: rect.midX - w / 2, y: rect.midY - h / 2)
                for crop in crops {
                    let r = crop.rect
                    let box = NSRect(x: origin.x + CGFloat(r[0]) * w, y: origin.y + (1 - CGFloat(r[3])) * h,
                                     width: CGFloat(r[2] - r[0]) * w, height: CGFloat(r[3] - r[1]) * h)
                    let path = NSBezierPath(rect: box); path.lineWidth = 2; path.stroke()
                    NSAttributedString(string: crop.name, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.systemYellow])
                        .draw(at: NSPoint(x: box.minX + 3, y: box.maxY - 15))
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.88]) else {
            throw StudioError.message("Vergleich konnte nicht gespeichert werden.")
        }
        try requireStori()
        let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"; day.locale = Locale(identifier: "en_US_POSIX")
        let folder = picturesDirectory.appendingPathComponent("Vergleiche/\(day.string(from: Date()))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = (p["name"] as? String).flatMap { $0.isEmpty ? nil : $0.replacingOccurrences(of: "/", with: "_") } ?? "vergleich-\(filenameStamp())"
        var target = folder.appendingPathComponent("\(base).jpg"), index = 2
        while FileManager.default.fileExists(atPath: target.path) { target = folder.appendingPathComponent("\(base)-\(index).jpg"); index += 1 }
        try data.write(to: target)
        return ["ok": true, "image": target.path, "resolution": [width, height],
                "columns": images.map { ["title": $0.title, "facts": $0.facts] },
                "rows": ["Ganzes Bild"] + crops.map(\.name)]
    }

    /// Title and fact line from the sidecar JSON (renders, videos) or the picture metadata, else size + file name.
    static func describe(_ url: URL, image: CGImage) -> (String, String) {
        var facts: [String] = []
        var title = url.deletingPathExtension().lastPathComponent
        let sidecar = url.deletingPathExtension().appendingPathExtension("json")
        if let data = try? Data(contentsOf: sidecar), let info = try? jsonDecoder().decode(MediaInfo.self, from: data) {
            title = info.title
            let s = info.settings ?? [:]
            if let camera = s["camera"], !camera.isEmpty { facts.append("Kamera \(camera)") }
            facts.append(s["resolution"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(image.width)×\(image.height)")
            if let samples = s["samples"], !samples.isEmpty { facts.append("\(samples) Samples") }
            if let engine = s["engine"], !engine.isEmpty, s["samples"] == nil { facts.append(engine.replacingOccurrences(of: "BLENDER_", with: "").capitalized) }
            if let source = s["source"], !source.isEmpty { facts.append(source) }
            if let seconds = info.seconds { facts.append(elapsedText(Double(seconds))) }
        } else if let data = try? Data(contentsOf: url.deletingPathExtension().appendingPathExtension("json")),
                  let meta = try? jsonDecoder().decode(RunMetadata.self, from: data) {
            title = String(meta.settings.prompt.prefix(60))
            facts += ["\(image.width)×\(image.height)", "Seed \(meta.actualSeed ?? meta.settings.seed)", elapsedText(meta.durationSeconds)]
        } else {
            facts.append("\(image.width)×\(image.height)")
            facts.append(url.lastPathComponent)
        }
        if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
            facts.append(date.formatted(date: .omitted, time: .shortened))
        }
        return (title, facts.joined(separator: " · "))
    }

    static func strings(_ value: Any?) -> [String] {
        if let list = value as? [String] { return list }
        if let list = value as? [Any] { return list.map { "\($0)" } }
        if let text = value as? String { return text.split(separator: text.contains("|") ? "|" : ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        return []
    }

    /// [{"name": "Kragen", "region": [x0,y0,x1,y1]}], [[x0,y0,x1,y1]] or "Kragen:0.4,0.1,0.6,0.3;Saum:…"
    static func parseCrops(_ value: Any?) throws -> [Crop] {
        var result: [Crop] = []
        func add(_ name: String, _ numbers: [Double]) throws {
            guard numbers.count == 4, numbers.allSatisfy({ (0...1).contains($0) }), numbers[2] - numbers[0] > 0.01, numbers[3] - numbers[1] > 0.01 else {
                throw StudioError.message("Ausschnitt „\(name)“: [x0, y0, x1, y1] als Anteile 0–1 von oben links, x0 < x1, y0 < y1.")
            }
            result.append(Crop(name: name, rect: numbers))
        }
        if let list = value as? [Any] {
            for (index, entry) in list.enumerated() {
                if let dict = entry as? [String: Any] {
                    try add(dict["name"] as? String ?? "Ausschnitt \(index + 1)", (dict["region"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.doubleValue })
                } else if let numbers = entry as? [Any] {
                    try add("Ausschnitt \(index + 1)", numbers.compactMap { ($0 as? NSNumber)?.doubleValue })
                }
            }
        } else if let text = value as? String, !text.isEmpty {
            for (index, part) in text.split(separator: ";").enumerated() {
                let pieces = part.split(separator: ":", maxSplits: 1)
                let name = pieces.count == 2 ? String(pieces[0]) : "Ausschnitt \(index + 1)"
                try add(name, (pieces.last ?? "").split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) })
            }
        }
        return result
    }
}
