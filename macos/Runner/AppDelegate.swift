import AVFoundation
import Cocoa
import FlutterMacOS
import ImageIO

@main
class AppDelegate: FlutterAppDelegate {
  private let mediaOpenChannelName = "c2pa_viewer/media_open"
  private let mediaProbeChannelName = "c2pa_viewer/media_probe"
  private var mediaOpenChannel: FlutterMethodChannel?
  private var pendingOpenFilePaths: [String] = []
  private var securityScopedMediaURLs: [String: [URL]] = [:]

  override func applicationDidFinishLaunching(_ notification: Notification) {
    guard
      let flutterViewController = mainFlutterWindow?.contentViewController
        as? FlutterViewController
    else {
      return
    }

    let openChannel = FlutterMethodChannel(
      name: mediaOpenChannelName,
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    mediaOpenChannel = openChannel
    openChannel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "consumePendingMediaFiles" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let paths = self?.pendingOpenFilePaths ?? []
      self?.pendingOpenFilePaths.removeAll()
      result(paths)
    }

    let probeChannel = FlutterMethodChannel(
      name: mediaProbeChannelName,
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    probeChannel.setMethodCallHandler { [weak self] call, result in
      guard
        let arguments = call.arguments as? [String: Any],
        let path = arguments["path"] as? String
      else {
        result(
          FlutterError(
            code: "invalid-arguments",
            message: "Expected a media file path.",
            details: nil
          )
        )
        return
      }
      switch call.method {
      case "beginAccessingMedia":
        result(self?.beginAccessingMedia(path: path) ?? false)
      case "endAccessingMedia":
        self?.endAccessingMedia(path: path)
        result(nil)
      case "probeMedia":
        self?.probeMedia(path: path, result: result)
      case "thumbnailForMedia":
        self?.thumbnailForMedia(path: path, result: result)
      case "probeExifMetadata":
        self?.probeExifMetadata(path: path, result: result)
      case "removeC2paFromMedia":
        guard let outputPath = arguments["outputPath"] as? String else {
          result(
            FlutterError(
              code: "invalid-arguments",
              message: "Expected an output media file path.",
              details: nil
            )
          )
          return
        }
        self?.removeC2paFromMedia(
          path: path,
          outputPath: outputPath,
          result: result
        )
      default:
        result(FlutterMethodNotImplemented)
      }
    }

  }

  override func application(_ sender: NSApplication, openFiles filenames: [String]) {
    queueOpenedMediaFiles(filenames, application: sender)
    sender.reply(toOpenOrPrint: .success)
  }

  override func application(_ application: NSApplication, open urls: [URL]) {
    queueOpenedMediaFiles(
      urls.filter(\.isFileURL).map(\.path),
      application: application
    )
  }

  override func applicationShouldTerminateAfterLastWindowClosed(
    _ sender: NSApplication
  ) -> Bool {
    true
  }

  override func applicationSupportsSecureRestorableState(
    _ app: NSApplication
  ) -> Bool {
    true
  }

  private func queueOpenedMediaFiles(
    _ paths: [String],
    application: NSApplication
  ) {
    for path in paths where !pendingOpenFilePaths.contains(path) {
      pendingOpenFilePaths.append(path)
    }
    guard !paths.isEmpty else { return }
    mainFlutterWindow?.makeKeyAndOrderFront(nil)
    application.activate(ignoringOtherApps: true)
    mediaOpenChannel?.invokeMethod("mediaFilesOpened", arguments: nil)
  }

  private func probeMedia(path: String, result: @escaping FlutterResult) {
    let url = URL(fileURLWithPath: path)
    let photoExtensions: Set<String> = [
      "jpg", "jpeg", "png", "webp", "heic", "heif",
    ]
    if photoExtensions.contains(url.pathExtension.lowercased()) {
      guard let image = NSImage(contentsOf: url) else {
        result(probeError(code: "invalid-image", path: path))
        return
      }
      let representation = image.representations.max {
        $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh
      }
      result([
        "width": representation?.pixelsWide ?? Int(image.size.width),
        "height": representation?.pixelsHigh ?? Int(image.size.height),
        "durationSeconds": 0,
        "hasAudio": false,
        "isPhoto": true,
      ])
      return
    }

    let asset = AVURLAsset(url: url)
    guard let videoTrack = asset.tracks(withMediaType: .video).first else {
      result(probeError(code: "no-video-track", path: path))
      return
    }
    let transformedSize = videoTrack.naturalSize.applying(
      videoTrack.preferredTransform
    )
    let durationSeconds = CMTimeGetSeconds(asset.duration)
    result([
      "width": Int(abs(transformedSize.width).rounded()),
      "height": Int(abs(transformedSize.height).rounded()),
      "durationSeconds": durationSeconds.isFinite ? durationSeconds : 0,
      "hasAudio": !asset.tracks(withMediaType: .audio).isEmpty,
      "isPhoto": false,
    ])
  }

  private func beginAccessingMedia(path: String) -> Bool {
    let url = URL(fileURLWithPath: path)
    guard url.startAccessingSecurityScopedResource() else { return false }
    securityScopedMediaURLs[path, default: []].append(url)
    return true
  }

  private func endAccessingMedia(path: String) {
    guard var urls = securityScopedMediaURLs[path], let url = urls.popLast()
    else { return }
    url.stopAccessingSecurityScopedResource()
    if urls.isEmpty {
      securityScopedMediaURLs.removeValue(forKey: path)
    } else {
      securityScopedMediaURLs[path] = urls
    }
  }


  private func thumbnailForMedia(path: String, result: @escaping FlutterResult) {
    let url = URL(fileURLWithPath: path)
    if let image = NSImage(contentsOf: url),
      let jpegData = thumbnailJPEG(for: image)
    {
      result(FlutterStandardTypedData(bytes: jpegData))
      return
    }
    let asset = AVURLAsset(url: url)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 512, height: 512)
    let time = CMTime(seconds: 0, preferredTimescale: 600)
    generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) {
      _, image, _, status, _ in
      if status == .succeeded, let image = image {
        let nsImage = NSImage(cgImage: image, size: .zero)
        if let jpegData = self.thumbnailJPEG(for: nsImage) {
          result(FlutterStandardTypedData(bytes: jpegData))
          return
        }
      }
      result(nil)
    }
  }

  private func thumbnailJPEG(for image: NSImage) -> Data? {
    guard let tiffData = image.tiffRepresentation,
      let bitmapRep = NSBitmapImageRep(data: tiffData)
    else { return nil }
    return bitmapRep.representation(
      using: .jpeg,
      properties: [.compressionFactor: 0.75]
    )
  }

  private func removeC2paFromMedia(
    path: String,
    outputPath: String,
    result: @escaping FlutterResult
  ) {
    let sourceURL = URL(fileURLWithPath: path)
    let outputURL = URL(fileURLWithPath: outputPath)
    let photoExtensions: Set<String> = [
      "jpg", "jpeg", "png", "webp", "heic", "heif",
    ]
    if photoExtensions.contains(sourceURL.pathExtension.lowercased()) {
      removeC2paFromImage(
        sourceURL: sourceURL,
        outputURL: outputURL,
        result: result
      )
      return
    }
    removeC2paFromVideo(
      sourceURL: sourceURL,
      outputURL: outputURL,
      result: result
    )
  }

  private func removeC2paFromImage(
    sourceURL: URL,
    outputURL: URL,
    result: FlutterResult
  ) {
    guard
      let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let imageType = CGImageSourceGetType(source),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL,
        imageType,
        1,
        nil
      )
    else {
      result(
        FlutterError(
          code: "c2pa-remove-failed",
          message: "The image could not be rewritten without C2PA.",
          details: sourceURL.path
        )
      )
      return
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      result(
        FlutterError(
          code: "c2pa-remove-failed",
          message: "The image could not be saved without C2PA.",
          details: outputURL.path
        )
      )
      return
    }
    result(nil)
  }

  private func removeC2paFromVideo(
    sourceURL: URL,
    outputURL: URL,
    result: @escaping FlutterResult
  ) {
    let asset = AVURLAsset(url: sourceURL)
    guard
      let exportSession = AVAssetExportSession(
        asset: asset,
        presetName: AVAssetExportPresetPassthrough
      ),
      let outputFileType = outputFileType(for: outputURL.pathExtension),
      exportSession.supportedFileTypes.contains(outputFileType)
    else {
      result(
        FlutterError(
          code: "c2pa-remove-unsupported",
          message: "Removing C2PA is not supported for this video format.",
          details: sourceURL.pathExtension
        )
      )
      return
    }
    exportSession.outputURL = outputURL
    exportSession.outputFileType = outputFileType
    exportSession.metadata = []
    exportSession.exportAsynchronously {
      switch exportSession.status {
      case .completed:
        result(nil)
      default:
        result(
          FlutterError(
            code: "c2pa-remove-failed",
            message: "The video could not be rewritten without C2PA.",
            details: exportSession.error?.localizedDescription
          )
        )
      }
    }
  }

  private func outputFileType(for extensionName: String) -> AVFileType? {
    switch extensionName.lowercased() {
    case "mp4", "m4v":
      return .mp4
    case "mov":
      return .mov
    default:
      return nil
    }
  }

  private func probeExifMetadata(path: String, result: @escaping FlutterResult) {
    let url = URL(fileURLWithPath: path)
    let ext = url.pathExtension.lowercased()
    var groups: [String: [String: String]] = [:]

    // FILE group — filesystem-level facts (mirrors ExifTool FILE group)
    var fileGroup: [String: String] = ["FileName": url.lastPathComponent]
    let attrs = try? FileManager.default.attributesOfItem(atPath: path)
    if let size = attrs?[.size] as? Int { fileGroup["FileSize"] = formatBytes(size) }
    if let modDate = attrs?[.modificationDate] as? Date { fileGroup["FileModifyDate"] = formatDate(modDate) }
    if let createDate = attrs?[.creationDate] as? Date { fileGroup["FileCreateDate"] = formatDate(createDate) }
    fileGroup["FileTypeExtension"] = ext.isEmpty ? "unknown" : ext
    let mimeMap: [String: (String, String)] = [
      "jpg": ("JPEG","image/jpeg"), "jpeg": ("JPEG","image/jpeg"),
      "png": ("PNG","image/png"),   "webp": ("WebP","image/webp"),
      "heic": ("HEIC","image/heic"), "heif": ("HEIF","image/heif"),
      "tif": ("TIFF","image/tiff"), "tiff": ("TIFF","image/tiff"),
      "mp4": ("MP4","video/mp4"),   "m4v": ("M4V","video/mp4"),
      "mov": ("MOV","video/quicktime"),
    ]
    if let (ft, mime) = mimeMap[ext] {
      fileGroup["FileType"] = ft
      fileGroup["MIMEType"] = mime
    }

    let photoExts: Set<String> = ["jpg","jpeg","png","webp","heic","heif","tif","tiff"]
    if photoExts.contains(ext) {
      guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
        groups["FILE"] = fileGroup
        result(groups)
        return
      }
      let pw = props["PixelWidth"] as? Int ?? 0
      let ph = props["PixelHeight"] as? Int ?? 0
      if pw > 0 { fileGroup["ImageWidth"] = "\(pw)" }
      if ph > 0 { fileGroup["ImageHeight"] = "\(ph)" }
      if let depth = props["Depth"] as? Int { fileGroup["BitsPerSample"] = "\(depth)" }
      if let comps = props["ColorComponents"] as? Int { fileGroup["ColorComponents"] = "\(comps)" }
      if let profile = props["ColorModel"] as? String { fileGroup["ColorSpace"] = profile }
      groups["FILE"] = fileGroup

      // Raw metadata namespaces from ImageIO (ExifTool-style group names)
      let nsMap: [(String, String)] = [
        ("{Exif}","EXIF"), ("{GPS}","GPS"), ("{IPTC}","IPTC"),
        ("{TIFF}","TIFF"), ("{JFIF}","JFIF"), ("{PNG}","PNG"),
        ("{GIF}","GIF"), ("{DNG}","DNG"),
      ]
      for (ioKey, groupName) in nsMap {
        guard let sub = props[ioKey] as? [String: Any], !sub.isEmpty else { continue }
        var g: [String: String] = [:]
        for (k, v) in sub { g[k] = formatMetaValue(v) }
        groups[groupName] = g
      }
      // MakerApple — decoded via ExifTool Apple.pm PrintConv mappings
      if let appleRaw = props["{MakerApple}"] as? [String: Any], !appleRaw.isEmpty {
        var g: [String: String] = [:]
        for (k, v) in appleRaw { g[k] = decodeMakerAppleTag(key: k, value: v) }
        groups["MakerApple"] = g
      }

      // XMP — via CGImageMetadata API (ExifTool XMP group)
      if let meta = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
        var xmpGroup: [String: String] = [:]
        if let tags = CGImageMetadataCopyTags(meta) as? [CGImageMetadataTag] {
          for tag in tags { collectXMPTags(tag: tag, prefix: "", into: &xmpGroup) }
        }
        if !xmpGroup.isEmpty { groups["XMP"] = xmpGroup }
      }

      // COMPOSITE — derived/computed fields (mirrors ExifTool COMPOSITE group)
      var composite: [String: String] = [:]
      if pw > 0 && ph > 0 {
        composite["ImageSize"] = "\(pw)x\(ph)"
        composite["Megapixels"] = String(format: "%.3g", Double(pw * ph) / 1_000_000.0)
      }
      if let orient = props["Orientation"] as? Int { composite["Orientation"] = "\(orient)" }
      buildImageComposite(exifGroup: groups["EXIF"], gpsGroup: groups["GPS"], into: &composite)
      if !composite.isEmpty { groups["COMPOSITE"] = composite }

    } else {
      // Video — AVFoundation
      let asset = AVURLAsset(url: url)
      var composite: [String: String] = [:]

      if let videoTrack = asset.tracks(withMediaType: .video).first {
        let size = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
        let w = Int(abs(size.width).rounded()); let h = Int(abs(size.height).rounded())
        if w > 0 && h > 0 {
          fileGroup["ImageWidth"] = "\(w)"; fileGroup["ImageHeight"] = "\(h)"
          composite["ImageSize"] = "\(w)x\(h)"
          composite["Megapixels"] = String(format: "%.3g", Double(w * h) / 1_000_000.0)
        }
        let fps = videoTrack.nominalFrameRate
        if fps > 0 { composite["VideoFrameRate"] = String(format: "%.3g fps", fps) }
        let bitrate = videoTrack.estimatedDataRate
        if bitrate > 0 { composite["AvgBitrate"] = String(format: "%.1f Mbps", bitrate / 1_000_000.0) }
        let t = videoTrack.preferredTransform
        if t.b == 1 && t.c == -1 { composite["Rotation"] = "90" }
        else if t.b == -1 && t.c == 1 { composite["Rotation"] = "270" }
        else if t.a == -1 && t.d == -1 { composite["Rotation"] = "180" }
        // Video codec FourCC (e.g. "avc1", "hvc1", "ap4h")
        if let desc = videoTrack.formatDescriptions.first {
          let codecType = CMFormatDescriptionGetMediaSubType(desc as! CMFormatDescription)
          let codecStr = fourCCToString(codecType)
          if !codecStr.isEmpty { composite["VideoCodec"] = codecStr }
        }
      }
      let dur = CMTimeGetSeconds(asset.duration)
      if dur > 0 && dur.isFinite {
        composite["Duration"] = String(format: "%.2f s", dur)
        let totalSec = Int(dur)
        if totalSec >= 60 {
          composite["DurationText"] = String(format: "%d:%02d:%02d",
            totalSec / 3600, (totalSec % 3600) / 60, totalSec % 60)
        }
      }
      groups["FILE"] = fileGroup
      groups["COMPOSITE"] = composite

      // Audio track — channels, sample rate, format (ExifTool Audio group)
      if let audioTrack = asset.tracks(withMediaType: .audio).first,
         let desc = audioTrack.formatDescriptions.first,
         let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(
           desc as! CMAudioFormatDescription) {
        var audioGroup: [String: String] = [:]
        audioGroup["AudioChannels"] = "\(asbd.pointee.mChannelsPerFrame)"
        if asbd.pointee.mSampleRate > 0 {
          audioGroup["AudioSampleRate"] = String(format: "%.0f Hz", asbd.pointee.mSampleRate)
        }
        let fmtStr = fourCCToString(asbd.pointee.mFormatID)
        if !fmtStr.isEmpty { audioGroup["AudioFormat"] = fmtStr }
        let br = audioTrack.estimatedDataRate
        if br > 0 { audioGroup["AudioBitrate"] = String(format: "%.0f kbps", br / 1_000.0) }
        groups["Audio"] = audioGroup
      }

      // QuickTime metadata — creation date, title, GPS, camera, etc.
      var qtGroup: [String: String] = [:]
      let formats: [AVMetadataFormat] = [.quickTimeMetadata, .iTunesMetadata]
      for fmt in formats {
        for item in asset.metadata(forFormat: fmt) {
          let key = (item.identifier?.rawValue ?? item.key?.description ?? "")
            .components(separatedBy: "/").last ?? ""
          guard !key.isEmpty else { continue }
          if let v = item.stringValue { qtGroup[key] = v }
          else if let v = item.dateValue { qtGroup[key] = formatDate(v) }
          else if let v = item.numberValue { qtGroup[key] = "\(v)" }
        }
      }
      for item in asset.commonMetadata {
        guard let key = item.commonKey?.rawValue else { continue }
        if let v = item.stringValue { qtGroup[key] = v }
        else if let v = item.dateValue { qtGroup[key] = formatDate(v) }
        else if let v = item.numberValue { qtGroup[key] = "\(v)" }
      }
      if !qtGroup.isEmpty { groups["QuickTime"] = qtGroup }
    }
    result(groups)
  }

  // MARK: - Metadata helpers

  /// Formats a Date as ExifTool-style "yyyy:MM:dd HH:mm:ssZ"
  private func formatDate(_ date: Date) -> String {
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy:MM:dd HH:mm:ssxxx"
    fmt.locale = Locale(identifier: "en_US_POSIX")
    return fmt.string(from: date)
  }

  /// Converts exposure time in seconds to fractional string (e.g. "1/100")
  private func formatExposureTime(_ seconds: Double) -> String {
    if seconds >= 1.0 { return String(format: "%.1f s", seconds) }
    let denom = (1.0 / seconds).rounded()
    return "1/\(Int(denom))"
  }

  /// Converts a FourCharCode to printable ASCII string (e.g. 0x61766331 → "avc1")
  private func fourCCToString(_ code: FourCharCode) -> String {
    let bytes: [UInt8] = [
      UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
      UInt8((code >> 8) & 0xFF),  UInt8(code & 0xFF),
    ]
    return (String(bytes: bytes, encoding: .ascii) ?? "").trimmingCharacters(in: .whitespaces)
  }

  /// Recursively flattens CGImageMetadataTag tree into a string dict (XMP extraction)
  private func collectXMPTags(tag: CGImageMetadataTag, prefix: String, into dict: inout [String: String]) {
    let name = (CGImageMetadataTagCopyName(tag) as String?) ?? ""
    let ns   = (CGImageMetadataTagCopyNamespace(tag) as String?) ?? ""
    // Build a short namespace prefix (last path component of URI)
    let nsPrefix = ns.split(separator: "/").last.map(String.init) ?? ns
    let qualifiedName = nsPrefix.isEmpty ? name : "\(nsPrefix):\(name)"
    let fullKey = prefix.isEmpty ? qualifiedName : "\(prefix).\(qualifiedName)"
    let value = CGImageMetadataTagCopyValue(tag)
    if let str = value as? String {
      dict[fullKey] = str
    } else if let num = value as? NSNumber {
      dict[fullKey] = "\(num)"
    } else if let children = value as? [CGImageMetadataTag] {
      for child in children { collectXMPTags(tag: child, prefix: fullKey, into: &dict) }
    } else if let d = value as? [String: Any] {
      for (k, v) in d { dict["\(fullKey).\(k)"] = "\(v)" }
    } else if let value = value {
      dict[fullKey] = "\(value)"
    }
  }

  /// Converts GPS DMS string (e.g. "37, 48, 45.6") + ref to signed decimal degrees
  private func decodeGPSCoord(dms: String, ref: String) -> Double? {
    let parts = dms.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    var decimal: Double
    if parts.count == 3,
       let d = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) {
      decimal = d + m / 60.0 + s / 3600.0
    } else if parts.count == 1, let d = Double(parts[0]) {
      decimal = d
    } else { return nil }
    if ref == "S" || ref == "W" { decimal = -decimal }
    return decimal
  }

  /// Decodes the EXIF Flash integer value to a human-readable string
  private func decodeFlash(_ val: Int) -> String {
    if val & 0x20 != 0 { return "No Flash Function" }
    let fired = val & 0x01 != 0
    if !fired { return "No Flash" }
    var desc = "Flash Fired"
    switch (val >> 1) & 0x03 {
    case 2: desc += ", Return not detected"
    case 3: desc += ", Return detected"
    default: break
    }
    switch (val >> 3) & 0x03 {
    case 1: desc += ", Forced"
    case 2: desc += ", Off"
    case 3: desc += ", Auto"
    default: break
    }
    if val & 0x40 != 0 { desc += ", Red-eye reduction" }
    return desc
  }

  /// Builds COMPOSITE fields derived from EXIF and GPS raw groups (ExifTool COMPOSITE group)
  private func buildImageComposite(
    exifGroup: [String: String]?,
    gpsGroup: [String: String]?,
    into composite: inout [String: String]
  ) {
    // Aperture (from FNumber)
    if let fn = exifGroup?["FNumber"], let fnVal = Double(fn) {
      composite["Aperture"] = String(format: "%.1f", fnVal)
    }
    // ShutterSpeed (from ExposureTime)
    if let et = exifGroup?["ExposureTime"], let etVal = Double(et) {
      composite["ShutterSpeed"] = formatExposureTime(etVal)
    }
    // ISO (first element of ISOSpeedRatings array)
    if let iso = exifGroup?["ISOSpeedRatings"] {
      let first = iso.split(separator: ",").first.map {
        $0.trimmingCharacters(in: .whitespaces)
      } ?? iso
      composite["ISO"] = first
    }
    // FocalLength35efl (from FocalLengthIn35mmFilm)
    if let fl35 = exifGroup?["FocalLengthIn35mmFilm"] {
      composite["FocalLength35efl"] = "\(fl35) mm"
    }
    // DateTimeOriginal
    if let dto = exifGroup?["DateTimeOriginal"] { composite["DateTimeOriginal"] = dto }
    // LensModel
    if let lm = exifGroup?["LensModel"] { composite["LensModel"] = lm }
    // ExposureCompensation (ExposureBiasValue)
    if let ev = exifGroup?["ExposureBiasValue"] { composite["ExposureCompensation"] = "\(ev) EV" }
    // Flash decoded
    if let flashStr = exifGroup?["Flash"], let flashVal = Int(flashStr) {
      composite["Flash"] = decodeFlash(flashVal)
    }
    // GPS decimal coordinates + position
    if let gps = gpsGroup,
       let latStr = gps["Latitude"], let latRef = gps["LatitudeRef"],
       let lonStr = gps["Longitude"], let lonRef = gps["LongitudeRef"],
       let latD = decodeGPSCoord(dms: latStr, ref: latRef),
       let lonD = decodeGPSCoord(dms: lonStr, ref: lonRef) {
      composite["GPSLatitude"]  = String(format: "%.6f°", latD)
      composite["GPSLongitude"] = String(format: "%.6f°", lonD)
      composite["GPSPosition"]  = String(format: "%.6f, %.6f", latD, lonD)
    }
    // GPSAltitude
    if let gps = gpsGroup, let altStr = gps["Altitude"], let altVal = Double(altStr) {
      let below = gps["AltitudeRef"] == "1"
      composite["GPSAltitude"] = String(format: "%s%.1f m", below ? "-" : "", altVal)
    }
  }




  /// Decodes MakerApple tag values using ExifTool Apple.pm PrintConv mappings.
  /// Binary PLIST fields are labeled "(Binary)" to avoid raw data noise.
  private func decodeMakerAppleTag(key: String, value: Any) -> String {
    // Binary PLIST blobs — not human-readable, skip raw bytes
    if value is Data { return "(Binary)" }

    let intVal = (value as? NSNumber)?.intValue

    switch key {
    case "HDRImageType":
      return switch intVal {
      case 3: "HDR Image"
      case 4: "Original Image"
      default: "\(value)"
      }
    case "AEStable":
      return intVal == 1 ? "Yes" : intVal == 0 ? "No" : "\(value)"
    case "AFStable":
      return intVal == 1 ? "Yes" : intVal == 0 ? "No" : "\(value)"
    case "ImageCaptureType":
      return switch intVal {
      case 1:  "ProRAW"
      case 2:  "Portrait"
      case 10: "Photo"
      case 11: "Manual"
      case 12: "Scene"
      default: "\(value)"
      }
    case "CameraType":
      return switch intVal {
      case 0: "Back Wide"
      case 1: "Back Normal (1x)"
      case 6: "Front"
      default: "\(value)"
      }
    case "ColorTemperature":
      if let n = intVal { return "\(n) K" }
      return "\(value)"
    case "AccelerationVector":
      // Array of 3 doubles: [x, y, z] in g units
      if let arr = value as? [Any], arr.count == 3 {
        let parts = arr.compactMap { Double("\($0)").map { String(format: "%.4f", $0) } }
        if parts.count == 3 { return "x=\(parts[0]), y=\(parts[1]), z=\(parts[2]) g" }
      }
      return formatMetaValue(value)
    case "FocusDistanceRange":
      // Already a string like "0.5 - 1.2" from ImageIO, just add unit if missing
      let s = "\(value)"
      return s.contains("m") ? s : "\(s) m"
    case "HDRHeadroom", "HDRGain", "LuminanceNoiseAmplitude", "SignalToNoiseRatio":
      if let d = Double("\(value)") { return String(format: "%.4f", d) }
      return "\(value)"
    // Binary PLIST tags (dict/array returned by ImageIO as nested types)
    case "AEMatrix", "ColorCorrectionMatrix",
         "SemanticStyle", "SemanticStyleRenderingVer", "SemanticStylePreset",
         "Apple_0x004e", "Apple_0x004f", "Apple_0x0054", "Apple_0x005a":
      if !(value is String) && !(value is NSNumber) { return "(Binary)" }
      return formatMetaValue(value)
    default:
      return formatMetaValue(value)
    }
  }

  private func formatBytes(_ n: Int) -> String {
    if n < 1024 { return "\(n) B" }
    if n < 1_048_576 { return String(format: "%.1f kB", Double(n) / 1024.0) }
    return String(format: "%.2f MB", Double(n) / 1_048_576.0)
  }

  private func formatMetaValue(_ v: Any) -> String {
    if let arr = v as? [Any] { return arr.map { "\($0)" }.joined(separator: ", ") }
    return "\(v)"
  }

  private func probeError(code: String, path: String) -> FlutterError {
    FlutterError(
      code: code,
      message: "Unable to inspect the selected media file.",
      details: path
    )
  }
}
