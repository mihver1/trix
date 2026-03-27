#!/usr/bin/swift

import AppKit
import Foundation

struct IconSpec {
    let filename: String
    let pointSize: Double
    let scale: Double
    let idiom: String

    var pixelSize: Int {
        Int((pointSize * scale).rounded())
    }

    var sizeString: String {
        if pointSize.rounded() == pointSize {
            return "\(Int(pointSize))x\(Int(pointSize))"
        }
        return "\(pointSize)x\(pointSize)"
    }

    var scaleString: String {
        if scale.rounded() == scale {
            return "\(Int(scale))x"
        }
        return "\(scale)x"
    }
}

struct MacIconSpec {
    let filename: String
    let pointSize: Int
    let scale: Int

    var pixelSize: Int {
        pointSize * scale
    }
}

let fileManager = FileManager.default
let scriptURL = URL(fileURLWithPath: #filePath)
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()

let sourceIconURL = repoRoot.appendingPathComponent("assets/branding/trix-mark.svg")
let iosCatalogURL = repoRoot.appendingPathComponent("apps/ios/TrixiOS/Resources/Assets.xcassets")
let iosAppIconURL = iosCatalogURL.appendingPathComponent("AppIcon.appiconset")
let macResourcesURL = repoRoot.appendingPathComponent("apps/macos/Sources/TrixMac/Resources")
let macCatalogURL = macResourcesURL.appendingPathComponent("Assets.xcassets")
let macAppIconURL = macCatalogURL.appendingPathComponent("AppIcon.appiconset")
let macIcnsURL = macResourcesURL.appendingPathComponent("AppIcon.icns")
let androidResURL = repoRoot.appendingPathComponent("apps/android/app/src/main/res")

guard let sourceImage = NSImage(contentsOf: sourceIconURL) else {
    fputs("Failed to load source icon at \(sourceIconURL.path)\n", stderr)
    exit(1)
}

extension NSColor {
    convenience init(hex: String, alpha: CGFloat = 1.0) {
        let sanitized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let value = UInt64(sanitized, radix: 16) ?? 0
        let red = CGFloat((value >> 16) & 0xFF) / 255.0
        let green = CGFloat((value >> 8) & 0xFF) / 255.0
        let blue = CGFloat(value & 0xFF) / 255.0
        self.init(calibratedRed: red, green: green, blue: blue, alpha: alpha)
    }
}

enum IconStyle {
    case apple
    case transparent
    case paddedTransparent(iconInsetRatio: CGFloat)
}

func ensureDirectory(_ url: URL) throws {
    try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
}

func removeIfExists(_ url: URL) throws {
    guard fileManager.fileExists(atPath: url.path) else { return }
    try fileManager.removeItem(at: url)
}

func writeText(_ text: String, to url: URL) throws {
    try ensureDirectory(url.deletingLastPathComponent())
    try text.write(to: url, atomically: true, encoding: .utf8)
}

func be32(_ value: UInt32) -> Data {
    withUnsafeBytes(of: value.bigEndian) { Data($0) }
}

func fourCC(_ value: String) -> Data {
    Data(value.utf8)
}

func gradientBackground(in rect: CGRect) {
    let gradient = NSGradient(
        colorsAndLocations:
            (NSColor(hex: "#132332"), CGFloat(0.0)),
            (NSColor(hex: "#0A131C"), CGFloat(0.58)),
            (NSColor(hex: "#050A0F"), CGFloat(1.0))
    )!
    gradient.draw(
        from: CGPoint(x: rect.minX, y: rect.maxY),
        to: CGPoint(x: rect.maxX, y: rect.minY),
        options: []
    )
}

func renderPNG(
    to destinationURL: URL,
    canvasSize: Int,
    style: IconStyle
) throws {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: canvasSize,
        pixelsHigh: canvasSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "IconGenerator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not allocate bitmap"])
    }

    bitmap.size = NSSize(width: canvasSize, height: canvasSize)
    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "IconGenerator", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create graphics context"])
    }
    NSGraphicsContext.current = context

    let rect = CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize)
    NSColor.clear.setFill()
    rect.fill()

    switch style {
    case .apple:
        gradientBackground(in: rect)
        sourceImage.draw(in: rect)
    case .transparent:
        sourceImage.draw(in: rect)
    case .paddedTransparent(let iconInsetRatio):
        let inset = CGFloat(canvasSize) * iconInsetRatio
        let imageRect = rect.insetBy(dx: inset, dy: inset)
        sourceImage.draw(in: imageRect)
    }

    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconGenerator", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not encode PNG"])
    }

    try ensureDirectory(destinationURL.deletingLastPathComponent())
    try data.write(to: destinationURL)
}

func generateIOSIcons() throws {
    let specs: [IconSpec] = [
        .init(filename: "iphone-notification-20@2x.png", pointSize: 20, scale: 2, idiom: "iphone"),
        .init(filename: "iphone-notification-20@3x.png", pointSize: 20, scale: 3, idiom: "iphone"),
        .init(filename: "iphone-settings-29@2x.png", pointSize: 29, scale: 2, idiom: "iphone"),
        .init(filename: "iphone-settings-29@3x.png", pointSize: 29, scale: 3, idiom: "iphone"),
        .init(filename: "iphone-spotlight-40@2x.png", pointSize: 40, scale: 2, idiom: "iphone"),
        .init(filename: "iphone-spotlight-40@3x.png", pointSize: 40, scale: 3, idiom: "iphone"),
        .init(filename: "iphone-app-60@2x.png", pointSize: 60, scale: 2, idiom: "iphone"),
        .init(filename: "iphone-app-60@3x.png", pointSize: 60, scale: 3, idiom: "iphone"),
        .init(filename: "ipad-notification-20@1x.png", pointSize: 20, scale: 1, idiom: "ipad"),
        .init(filename: "ipad-notification-20@2x.png", pointSize: 20, scale: 2, idiom: "ipad"),
        .init(filename: "ipad-settings-29@1x.png", pointSize: 29, scale: 1, idiom: "ipad"),
        .init(filename: "ipad-settings-29@2x.png", pointSize: 29, scale: 2, idiom: "ipad"),
        .init(filename: "ipad-spotlight-40@1x.png", pointSize: 40, scale: 1, idiom: "ipad"),
        .init(filename: "ipad-spotlight-40@2x.png", pointSize: 40, scale: 2, idiom: "ipad"),
        .init(filename: "ipad-app-76@1x.png", pointSize: 76, scale: 1, idiom: "ipad"),
        .init(filename: "ipad-app-76@2x.png", pointSize: 76, scale: 2, idiom: "ipad"),
        .init(filename: "ipad-pro-app-83.5@2x.png", pointSize: 83.5, scale: 2, idiom: "ipad"),
        .init(filename: "ios-marketing-1024@1x.png", pointSize: 1024, scale: 1, idiom: "ios-marketing"),
    ]

    try removeIfExists(iosAppIconURL)
    try ensureDirectory(iosAppIconURL)

    for spec in specs {
        try renderPNG(
            to: iosAppIconURL.appendingPathComponent(spec.filename),
            canvasSize: spec.pixelSize,
            style: .apple
        )
    }

    let imageEntries = specs.map { spec -> String in
        var lines = [
            "      {",
            "        \"filename\" : \"\(spec.filename)\",",
            "        \"idiom\" : \"\(spec.idiom)\",",
            "        \"scale\" : \"\(spec.scaleString)\",",
            "        \"size\" : \"\(spec.sizeString)\"",
        ]
        lines.append("      }")
        return lines.joined(separator: "\n")
    }.joined(separator: ",\n")

    let contents = """
    {
      "images" : [
    \(imageEntries)
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }
    """
    try writeText(contents + "\n", to: iosAppIconURL.appendingPathComponent("Contents.json"))
    try writeText(
        """
        {
          "info" : {
            "author" : "xcode",
            "version" : 1
          }
        }
        """,
        to: iosCatalogURL.appendingPathComponent("Contents.json")
    )
}

func generateMacIcons() throws {
    let specs: [MacIconSpec] = [
        .init(filename: "mac-16.png", pointSize: 16, scale: 1),
        .init(filename: "mac-16@2x.png", pointSize: 16, scale: 2),
        .init(filename: "mac-32.png", pointSize: 32, scale: 1),
        .init(filename: "mac-32@2x.png", pointSize: 32, scale: 2),
        .init(filename: "mac-128.png", pointSize: 128, scale: 1),
        .init(filename: "mac-128@2x.png", pointSize: 128, scale: 2),
        .init(filename: "mac-256.png", pointSize: 256, scale: 1),
        .init(filename: "mac-256@2x.png", pointSize: 256, scale: 2),
        .init(filename: "mac-512.png", pointSize: 512, scale: 1),
        .init(filename: "mac-512@2x.png", pointSize: 512, scale: 2),
    ]

    try ensureDirectory(macResourcesURL)
    try removeIfExists(macAppIconURL)
    try ensureDirectory(macAppIconURL)

    for spec in specs {
        try renderPNG(
            to: macAppIconURL.appendingPathComponent(spec.filename),
            canvasSize: spec.pixelSize,
            style: .apple
        )
    }

    let contentsEntries = specs.map { spec in
        """
              {
                "filename" : "\(spec.filename)",
                "idiom" : "mac",
                "scale" : "\(spec.scale)x",
                "size" : "\(spec.pointSize)x\(spec.pointSize)"
              }
        """
    }.joined(separator: ",\n")

    let contents = """
    {
      "images" : [
    \(contentsEntries)
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }
    """
    try writeText(contents + "\n", to: macAppIconURL.appendingPathComponent("Contents.json"))
    try writeText(
        """
        {
          "info" : {
            "author" : "xcode",
            "version" : 1
          }
        }
        """,
        to: macCatalogURL.appendingPathComponent("Contents.json")
    )

    let icnsChunks: [(String, URL)] = [
        ("icp4", macAppIconURL.appendingPathComponent("mac-16.png")),
        ("icp5", macAppIconURL.appendingPathComponent("mac-16@2x.png")),
        ("icp6", macAppIconURL.appendingPathComponent("mac-32@2x.png")),
        ("ic07", macAppIconURL.appendingPathComponent("mac-128.png")),
        ("ic08", macAppIconURL.appendingPathComponent("mac-128@2x.png")),
        ("ic09", macAppIconURL.appendingPathComponent("mac-256@2x.png")),
        ("ic10", macAppIconURL.appendingPathComponent("mac-512@2x.png")),
    ]

    var payload = Data()
    for (chunkType, fileURL) in icnsChunks {
        let pngData = try Data(contentsOf: fileURL)
        payload.append(fourCC(chunkType))
        payload.append(be32(UInt32(pngData.count + 8)))
        payload.append(pngData)
    }

    var icnsData = Data()
    icnsData.append(fourCC("icns"))
    icnsData.append(be32(UInt32(payload.count + 8)))
    icnsData.append(payload)
    try icnsData.write(to: macIcnsURL)
}

func generateAndroidIcons() throws {
    let legacySizes = [
        ("mipmap-mdpi", 48),
        ("mipmap-hdpi", 72),
        ("mipmap-xhdpi", 96),
        ("mipmap-xxhdpi", 144),
        ("mipmap-xxxhdpi", 192),
    ]

    for (directory, size) in legacySizes {
        let baseURL = androidResURL.appendingPathComponent(directory)
        try ensureDirectory(baseURL)
        try renderPNG(
            to: baseURL.appendingPathComponent("ic_launcher.png"),
            canvasSize: size,
            style: .transparent
        )
        try renderPNG(
            to: baseURL.appendingPathComponent("ic_launcher_round.png"),
            canvasSize: size,
            style: .transparent
        )
    }

    let drawableNoDpiURL = androidResURL.appendingPathComponent("drawable-nodpi")
    try ensureDirectory(drawableNoDpiURL)
    try renderPNG(
        to: drawableNoDpiURL.appendingPathComponent("ic_launcher_foreground_image.png"),
        canvasSize: 432,
        style: .paddedTransparent(iconInsetRatio: 0.0972222222)
    )

    let anyDpiURL = androidResURL.appendingPathComponent("mipmap-anydpi-v26")
    try ensureDirectory(anyDpiURL)
    try writeText(
        """
        <?xml version="1.0" encoding="utf-8"?>
        <adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
            <background android:drawable="@drawable/ic_launcher_background" />
            <foreground android:drawable="@drawable/ic_launcher_foreground" />
        </adaptive-icon>
        """,
        to: anyDpiURL.appendingPathComponent("ic_launcher.xml")
    )
    try writeText(
        """
        <?xml version="1.0" encoding="utf-8"?>
        <adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
            <background android:drawable="@drawable/ic_launcher_background" />
            <foreground android:drawable="@drawable/ic_launcher_foreground" />
        </adaptive-icon>
        """,
        to: anyDpiURL.appendingPathComponent("ic_launcher_round.xml")
    )

    try removeIfExists(androidResURL.appendingPathComponent("values/icon_colors.xml"))
}

do {
    try generateIOSIcons()
    try generateMacIcons()
    try generateAndroidIcons()
    print("Generated app icons for iOS, Android, and macOS.")
} catch {
    fputs("Icon generation failed: \(error)\n", stderr)
    exit(1)
}
