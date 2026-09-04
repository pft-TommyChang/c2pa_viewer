import AVFoundation
import C2PA
import Flutter
import Photos
import PhotosUI
import UIKit

// C2PA native handler — registered by AppDelegate onto the Flutter engine's
// binary messenger. Requires c2pa-swift added via Xcode > Add Package
// Dependencies: https://github.com/contentauth/c2pa-swift.git (tag 0.0.12+)
//
// Supported methods (all called on a background thread):
//   signFile   – sign source → dest, supports images + video
//   readManifest – return raw manifest JSON string (nil if no C2PA data)
//   pickOriginalMedia   – present PHPicker and export selected asset's original binary to a temp path
//   removeFile          – strip C2PA from a file (images: re-encode; video: binary box strip)
//   saveToPhotoLibrary – save a signed image/video without re-encoding it

@available(iOS 16, *)
final class C2paNativeHandler: NSObject {

  static let channelName = "c2pa_native"

  // Stores the pending FlutterResult while PHPickerViewController is presented.
  private var pendingPickResult: FlutterResult?

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: messenger
    )
    let handler = C2paNativeHandler()
    channel.setMethodCallHandler { call, result in
      // Dispatch to background thread so we don't block the UI.
      DispatchQueue.global(qos: .userInitiated).async {
        handler.handle(call, result: result)
      }
    }
  }

  // MARK: - Dispatch

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    // pickOriginalMedia takes no arguments — dispatch before the args guard.
    if call.method == "pickOriginalMedia" {
      pickOriginalMedia(result: result)
      return
    }

    guard let args = call.arguments as? [String: Any] else {
      complete(
        result,
        with: FlutterError(
          code: "BAD_ARGS",
          message: "Expected dictionary args",
          details: nil
        )
      )
      return
    }
    switch call.method {
    case "signFile":
      signFile(args: args, result: result)
    case "thumbnailForMedia":
      thumbnailForMedia(args: args, result: result)
    case "readManifest":
      readManifest(args: args, result: result)
    case "readManifestWithResources":
      readManifestWithResources(args: args, result: result)
    case "removeFile":
      removeFile(args: args, result: result)
    case "probeExifMetadata":
      probeExifMetadata(args: args, result: result)
    case "saveToPhotoLibrary":
      saveToPhotoLibrary(args: args, result: result)
    default:
      complete(result, with: FlutterMethodNotImplemented)
    }
  }

  // MARK: - pickOriginalMedia

  /// Presents PHPickerViewController and exports the selected asset's original binary
  /// (HEIC, JPEG, MOV, MP4, …) to a temporary file, preserving all embedded metadata
  /// including C2PA. Returns the temp file path, or nil when the user cancels.
  private func pickOriginalMedia(result: @escaping FlutterResult) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      var config = PHPickerConfiguration()  // No photoLibrary — no extra permission needed.
      config.selectionLimit = 1
      config.filter = .any(of: [.images, .videos])

      let picker = PHPickerViewController(configuration: config)
      picker.delegate = self
      self.pendingPickResult = result

      guard let scene = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .first(where: { $0.activationState == .foregroundActive }),
        let rootVC = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
      else {
        self.complete(result, with: FlutterError(
          code: "NO_ROOT_VC", message: "No active root view controller", details: nil
        ))
        return
      }
      var topVC = rootVC
      while let presented = topVC.presentedViewController { topVC = presented }
      topVC.present(picker, animated: true)
    }
  }

  // MARK: - signFile

  private func signFile(args: [String: Any], result: @escaping FlutterResult) {
    guard
      let sourcePath  = args["sourcePath"]  as? String,
      let outputPath  = args["outputPath"]  as? String,
      let mimeType    = args["mimeType"]    as? String,
      let certPem     = args["certPem"]     as? String,
      let keyPem      = args["keyPem"]      as? String,
      let title       = args["title"]       as? String,
      let mode        = args["mode"]        as? String
    else {
      complete(
        result,
        with: FlutterError(
          code: "BAD_ARGS",
          message: "Missing required signFile args",
          details: nil
        )
      )
      return
    }

    // Generate a thumbnail and write it to a temp file so it can be streamed
    // into the manifest as a claim thumbnail resource.
    let thumbURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("c2pa_thumb_\(UUID().uuidString).jpg")
    let hasThumbnail: Bool
    if let thumbData = generateThumbnailData(for: URL(fileURLWithPath: sourcePath)) {
      hasThumbnail = (try? thumbData.write(to: thumbURL)) != nil
    } else {
      hasThumbnail = false
    }
    defer { try? FileManager.default.removeItem(at: thumbURL) }

    let manifestJSON = buildManifestJSON(title: title, mimeType: mimeType, hasThumbnail: hasThumbnail)

    do {
      let signerInfo = SignerInfo(
        algorithm: .es256,
        certificatePEM: certPem,
        privateKeyPEM: keyPem,
        tsa: nil
      )
      let source = URL(fileURLWithPath: sourcePath)
      let dest   = URL(fileURLWithPath: outputPath)

      // Ensure output directory exists
      try FileManager.default.createDirectory(
        at: dest.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )

      let sourceStream = try Stream(readFrom: source)
      let destinationStream = try Stream(writeTo: dest)
      let signer = try Signer(info: signerInfo)
      let builder = try Builder(manifestJSON: manifestJSON)
      switch mode {
      case "add":
        if hasManifest(source, format: mimeType) {
          // Preserve the existing provenance as the single parent ingredient.
          try builder.setIntent(.edit)
          let ingredientStream = try Stream(readFrom: source)
          try builder.addIngredient(
            json: buildParentIngredientJSON(
              title: source.lastPathComponent,
              mimeType: mimeType
            ),
            format: mimeType,
            from: ingredientStream
          )
        } else {
          // An unsigned source starts its first provenance chain.
          try builder.setIntent(.create(.digitalCreation))
        }
      case "replace":
        // Start a new provenance chain rather than retaining the old manifest
        // as a parent ingredient.
        try builder.setIntent(.create(.digitalCreation))
      default:
        throw NativeC2paError.unsupportedWriteMode(mode)
      }
      if hasThumbnail {
        let thumbStream = try Stream(readFrom: thumbURL)
        try builder.addResource(uri: "thumbnail", stream: thumbStream)
      }
      _ = try builder.sign(
        format: mimeType,
        source: sourceStream,
        destination: destinationStream,
        signer: signer
      )
      complete(result, with: nil)
    } catch {
      complete(
        result,
        with: FlutterError(
          code: "SIGN_FAILED",
          message: error.localizedDescription,
          details: "\(error)"
        )
      )
    }
  }

  // MARK: - removeFile

  /// Strips all C2PA data from the source and writes the clean file to outputPath.
  /// Images: re-encoded via CGImageSource/Destination (drops all metadata, no quality flag needed).
  /// Video (mp4/mov): binary box-level strip of top-level uuid/c2pa boxes.
  private func removeFile(args: [String: Any], result: @escaping FlutterResult) {
    guard
      let sourcePath = args["sourcePath"] as? String,
      let outputPath = args["outputPath"] as? String
    else {
      complete(result, with: FlutterError(code: "BAD_ARGS", message: "Missing sourcePath or outputPath", details: nil))
      return
    }

    let source = URL(fileURLWithPath: sourcePath)
    let dest   = URL(fileURLWithPath: outputPath)

    do {
      try FileManager.default.createDirectory(
        at: dest.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      if isVideo(source) {
        try removeC2paFromVideo(source, to: dest)
      } else {
        try removeC2paFromImage(source, to: dest)
      }
      complete(result, with: nil)
    } catch {
      complete(result, with: FlutterError(
        code: "REMOVE_FAILED",
        message: error.localizedDescription,
        details: "\(error)"
      ))
    }
  }

  /// Re-encodes the image without any metadata, effectively stripping C2PA and all other metadata.
  private func removeC2paFromImage(_ source: URL, to destination: URL) throws {
    guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else {
      throw NativeC2paError.removalFailed("Could not read image at \(source.lastPathComponent)")
    }
    let uti = CGImageSourceGetType(imageSource) ?? ("public.jpeg" as CFString)
    guard let dest = CGImageDestinationCreateWithURL(destination as CFURL, uti, 1, nil) else {
      throw NativeC2paError.removalFailed("Could not create output image destination")
    }
    guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
      throw NativeC2paError.removalFailed("Could not decode image pixels")
    }
    // Adding the raw CGImage (pixel data only) without the original metadata
    // properties means no EXIF, XMP, or C2PA data is written to the output.
    CGImageDestinationAddImage(dest, cgImage, nil)
    guard CGImageDestinationFinalize(dest) else {
      throw NativeC2paError.removalFailed("Could not write output image")
    }
  }

  /// Strips top-level C2PA uuid boxes and c2pa boxes from an MP4/MOV file
  /// by parsing ISO Base Media File Format (ISOBMFF) boxes at the file level.
  private func removeC2paFromVideo(_ source: URL, to destination: URL) throws {
    let data = try Data(contentsOf: source)
    var output = Data()
    var offset = 0

    // C2PA manifest UUID in ISOBMFF: d8fec3d6-1d34-f040-b1ba-bb4be5dc35ca
    let c2paUUID: [UInt8] = [
      0xd8, 0xfe, 0xc3, 0xd6, 0x1d, 0x34, 0xf0, 0x40,
      0xb1, 0xba, 0xbb, 0x4b, 0xe5, 0xdc, 0x35, 0xca,
    ]

    while offset + 8 <= data.count {
      // Read 4-byte big-endian box size
      let b = data[offset..<(offset + 4)]
      let rawSize = (Int(b[b.startIndex]) << 24) | (Int(b[b.startIndex+1]) << 16)
                  | (Int(b[b.startIndex+2]) << 8)  |  Int(b[b.startIndex+3])

      let typeBytes = data[(offset+4)..<(offset+8)]
      let boxType   = String(bytes: typeBytes, encoding: .ascii) ?? ""

      // Determine box total size and header size from rawSize field.
      var totalSize: Int
      var headerSize: Int
      if rawSize == 1 {
        // Extended 64-bit size stored in bytes 8-15
        guard offset + 16 <= data.count else { break }
        let eb = data[(offset+8)..<(offset+16)]
        totalSize  = (Int(eb[eb.startIndex])   << 56) | (Int(eb[eb.startIndex+1]) << 48)
                   | (Int(eb[eb.startIndex+2]) << 40) | (Int(eb[eb.startIndex+3]) << 32)
                   | (Int(eb[eb.startIndex+4]) << 24) | (Int(eb[eb.startIndex+5]) << 16)
                   | (Int(eb[eb.startIndex+6]) <<  8) |  Int(eb[eb.startIndex+7])
        headerSize = 16
      } else if rawSize == 0 {
        // Box extends to end of file
        totalSize  = data.count - offset
        headerSize = 8
      } else {
        totalSize  = rawSize
        headerSize = 8
      }

      guard totalSize > 0, offset + totalSize <= data.count else { break }

      // Decide whether to skip this box
      var skip = (boxType == "c2pa")
      if !skip && boxType == "uuid" && offset + headerSize + 16 <= data.count {
        let uuidStart = offset + headerSize
        let boxUUID   = Array(data[uuidStart..<(uuidStart + 16)])
        skip = (boxUUID == c2paUUID)
      }

      if !skip {
        output.append(data[offset..<(offset + totalSize)])
      }
      offset += totalSize
    }

    try output.write(to: destination)
  }

  // MARK: - saveToPhotoLibrary

  private func saveToPhotoLibrary(args: [String: Any], result: @escaping FlutterResult) {
    guard let filePath = args["path"] as? String else {
      complete(
        result,
        with: FlutterError(code: "BAD_ARGS", message: "Missing path", details: nil)
      )
      return
    }

    let fileURL = URL(fileURLWithPath: filePath)
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      complete(
        result,
        with: FlutterError(
          code: "FILE_NOT_FOUND",
          message: "The signed media file does not exist.",
          details: filePath
        )
      )
      return
    }

    PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
      guard let self else { return }
      guard status == .authorized || status == .limited else {
        self.complete(
          result,
          with: FlutterError(
            code: "PHOTO_PERMISSION_DENIED",
            message: "Photo Library add permission was denied.",
            details: nil
          )
        )
        return
      }

      PHPhotoLibrary.shared().performChanges {
        if self.isVideo(fileURL) {
          PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
        } else {
          // Use resource-based API to preserve exact binary content (including C2PA metadata).
          // creationRequestForAssetFromImage re-encodes the image and strips embedded metadata.
          let creationRequest = PHAssetCreationRequest.forAsset()
          let resourceOptions = PHAssetResourceCreationOptions()
          resourceOptions.shouldMoveFile = false
          creationRequest.addResource(with: .photo, fileURL: fileURL, options: resourceOptions)
        }
      } completionHandler: { success, error in
        if success {
          self.complete(result, with: nil)
        } else {
          self.complete(
            result,
            with: FlutterError(
              code: "PHOTO_SAVE_FAILED",
              message: error?.localizedDescription ?? "Could not save media to Photos.",
              details: error.map { "\($0)" }
            )
          )
        }
      }
    }
  }

  // MARK: - probeExifMetadata

  private func probeExifMetadata(args: [String: Any], result: @escaping FlutterResult) {
    guard let path = args["path"] as? String else { complete(result, with: nil); return }
    let url = URL(fileURLWithPath: path)
    let ext = url.pathExtension.lowercased()
    var groups: [String: [String: String]] = [:]

    // FILE group — filesystem-level facts (mirrors ExifTool FILE group)
    var fileGroup: [String: String] = ["FileName": url.lastPathComponent]
    let attrs = try? FileManager.default.attributesOfItem(atPath: path)
    if let size = attrs?[.size] as? Int {
      let bytes = size
      if bytes < 1024 { fileGroup["FileSize"] = "\(bytes) B" }
      else if bytes < 1_048_576 { fileGroup["FileSize"] = String(format: "%.1f kB", Double(bytes)/1024) }
      else { fileGroup["FileSize"] = String(format: "%.2f MB", Double(bytes)/1_048_576) }
    }
    if let modDate = attrs?[.modificationDate] as? Date { fileGroup["FileModifyDate"] = formatDate(modDate) }
    if let createDate = attrs?[.creationDate] as? Date  { fileGroup["FileCreateDate"] = formatDate(createDate) }
    fileGroup["FileTypeExtension"] = ext.isEmpty ? "unknown" : ext
    let mimeMap: [String: (String, String)] = [
      "jpg":("JPEG","image/jpeg"), "jpeg":("JPEG","image/jpeg"),
      "png":("PNG","image/png"),   "webp":("WebP","image/webp"),
      "heic":("HEIC","image/heic"), "heif":("HEIF","image/heif"),
      "mp4":("MP4","video/mp4"),   "m4v":("M4V","video/mp4"),
      "mov":("MOV","video/quicktime"),
    ]
    if let (ft, mime) = mimeMap[ext] { fileGroup["FileType"] = ft; fileGroup["MIMEType"] = mime }

    let photoExts: Set<String> = ["jpg","jpeg","png","webp","heic","heif","tif","tiff"]
    if photoExts.contains(ext) {
      guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
        groups["FILE"] = fileGroup
        complete(result, with: groups)
        return
      }
      let pw = props["PixelWidth"] as? Int ?? 0
      let ph = props["PixelHeight"] as? Int ?? 0
      if pw > 0 { fileGroup["ImageWidth"] = "\(pw)" }
      if ph > 0 { fileGroup["ImageHeight"] = "\(ph)" }
      if let depth = props["Depth"] as? Int { fileGroup["BitsPerSample"] = "\(depth)" }
      if let comps = props["ColorComponents"] as? Int { fileGroup["ColorComponents"] = "\(comps)" }
      groups["FILE"] = fileGroup

      // Raw metadata namespaces from ImageIO (ExifTool-style group names)
      let nsMap: [(String, String)] = [
        ("{Exif}","EXIF"), ("{GPS}","GPS"), ("{IPTC}","IPTC"),
        ("{TIFF}","TIFF"), ("{JFIF}","JFIF"), ("{PNG}","PNG"),
      ]
      for (ioKey, groupName) in nsMap {
        guard let sub = props[ioKey] as? [String: Any], !sub.isEmpty else { continue }
        var g: [String: String] = [:]
        for (k, v) in sub {
          if let arr = v as? [Any] { g[k] = arr.map { "\($0)" }.joined(separator: ", ") }
          else { g[k] = "\(v)" }
        }
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
      if let vt = asset.tracks(withMediaType: .video).first {
        let sz = vt.naturalSize.applying(vt.preferredTransform)
        let w = Int(abs(sz.width).rounded()); let h = Int(abs(sz.height).rounded())
        if w > 0 && h > 0 {
          fileGroup["ImageWidth"] = "\(w)"; fileGroup["ImageHeight"] = "\(h)"
          composite["ImageSize"] = "\(w)x\(h)"
          composite["Megapixels"] = String(format: "%.3g", Double(w*h)/1_000_000.0)
        }
        let fps = vt.nominalFrameRate
        if fps > 0 { composite["VideoFrameRate"] = String(format: "%.3g fps", fps) }
        let br = vt.estimatedDataRate
        if br > 0 { composite["AvgBitrate"] = String(format: "%.1f Mbps", br/1_000_000.0) }
        let t = vt.preferredTransform
        if t.b == 1 && t.c == -1 { composite["Rotation"] = "90" }
        else if t.b == -1 && t.c == 1 { composite["Rotation"] = "270" }
        else if t.a == -1 && t.d == -1 { composite["Rotation"] = "180" }
        // Video codec FourCC (e.g. "avc1", "hvc1")
        if let desc = vt.formatDescriptions.first {
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
    complete(result, with: groups)
  }

  // MARK: - Metadata helpers

  /// Formats a Date as ExifTool-style "yyyy:MM:dd HH:mm:ssZ"

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
      return (value as? [Any]).map { $0.map { "\($0)" }.joined(separator: ", ") } ?? "\(value)"
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
      return "\(value)"
    default:
      return (value as? [Any]).map { $0.map { "\($0)" }.joined(separator: ", ") } ?? "\(value)"
    }
  }

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
    if let fn = exifGroup?["FNumber"], let fnVal = Double(fn) {
      composite["Aperture"] = String(format: "%.1f", fnVal)
    }
    if let et = exifGroup?["ExposureTime"], let etVal = Double(et) {
      composite["ShutterSpeed"] = formatExposureTime(etVal)
    }
    if let iso = exifGroup?["ISOSpeedRatings"] {
      let first = iso.split(separator: ",").first.map {
        $0.trimmingCharacters(in: .whitespaces)
      } ?? iso
      composite["ISO"] = first
    }
    if let fl35 = exifGroup?["FocalLengthIn35mmFilm"] { composite["FocalLength35efl"] = "\(fl35) mm" }
    if let dto = exifGroup?["DateTimeOriginal"] { composite["DateTimeOriginal"] = dto }
    if let lm = exifGroup?["LensModel"] { composite["LensModel"] = lm }
    if let ev = exifGroup?["ExposureBiasValue"] { composite["ExposureCompensation"] = "\(ev) EV" }
    if let flashStr = exifGroup?["Flash"], let flashVal = Int(flashStr) {
      composite["Flash"] = decodeFlash(flashVal)
    }
    if let gps = gpsGroup,
       let latStr = gps["Latitude"], let latRef = gps["LatitudeRef"],
       let lonStr = gps["Longitude"], let lonRef = gps["LongitudeRef"],
       let latD = decodeGPSCoord(dms: latStr, ref: latRef),
       let lonD = decodeGPSCoord(dms: lonStr, ref: lonRef) {
      composite["GPSLatitude"]  = String(format: "%.6f°", latD)
      composite["GPSLongitude"] = String(format: "%.6f°", lonD)
      composite["GPSPosition"]  = String(format: "%.6f, %.6f", latD, lonD)
    }
    if let gps = gpsGroup, let altStr = gps["Altitude"], let altVal = Double(altStr) {
      let below = gps["AltitudeRef"] == "1"
      composite["GPSAltitude"] = String(format: "%s%.1f m", below ? "-" : "", altVal)
    }
  }



  // MARK: - readManifestWithResources

  /// Reads the manifest JSON and writes thumbnails to outputDir using the same
  /// directory structure as c2patool --output, so _resourcePathFor can resolve them.
  /// Identifier pattern: self#jumbf=/c2pa/<label>/<resource> →
  /// outputDir/<label with : → _>/<resource>
  private func readManifestWithResources(args: [String: Any], result: @escaping FlutterResult) {
    guard
      let sourcePath = args["sourcePath"] as? String,
      let outputDir  = args["outputDir"]  as? String
    else {
      complete(result, with: nil)
      return
    }
    let sourceURL = URL(fileURLWithPath: sourcePath)
    guard let format = mimeType(for: sourceURL) else {
      complete(result, with: nil)
      return
    }
    do {
      let stream  = try Stream(readFrom: sourceURL)
      let reader  = try Reader(format: format, stream: stream)
      let jsonStr = try reader.json()

      // Parse JSON to find manifest labels + thumbnail identifiers, then write
      // generated thumbnails to the expected paths so the Flutter layer can load them.
      if let jsonData = jsonStr.data(using: .utf8),
         let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
         let manifests = root["manifests"] as? [String: Any] {

        // Generate thumbnail once (lazily) and reuse across manifests.
        var thumbData: Data? = nil

        for (_, manifestValue) in manifests {
          guard let manifest = manifestValue as? [String: Any],
                let thumbnail = manifest["thumbnail"] as? [String: Any],
                let identifier = thumbnail["identifier"] as? String else { continue }

          let prefix = "self#jumbf=/c2pa/"
          guard identifier.hasPrefix(prefix) else { continue }

          let remaining = String(identifier.dropFirst(prefix.count))
          let segments  = remaining.components(separatedBy: "/")
          guard segments.count >= 2 else { continue }

          let manifestDirName = segments[0].replacingOccurrences(of: ":", with: "_")
          let resourceName    = segments.dropFirst().joined(separator: "/")

          let resourceURL = URL(fileURLWithPath: outputDir)
            .appendingPathComponent(manifestDirName)
            .appendingPathComponent(resourceName)

          try? FileManager.default.createDirectory(
            at: resourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
          )
          // Generate thumbnail on first manifest that needs one, then reuse.
          if thumbData == nil { thumbData = generateThumbnailData(for: sourceURL) }
          if let data = thumbData { try? data.write(to: resourceURL) }
        }
      }

      complete(result, with: jsonStr)
    } catch {
      complete(result, with: nil)
    }
  }

  // MARK: - readManifest

  private func readManifest(args: [String: Any], result: @escaping FlutterResult) {
    guard let filePath = args["path"] as? String else {
      complete(
        result,
        with: FlutterError(code: "BAD_ARGS", message: "Missing path", details: nil)
      )
      return
    }
    do {
      let fileURL = URL(fileURLWithPath: filePath)
      guard let format = mimeType(for: fileURL) else {
        complete(
          result,
          with: FlutterError(
            code: "UNSUPPORTED_FORMAT",
            message: "Unsupported media extension: .\(fileURL.pathExtension)",
            details: nil
          )
        )
        return
      }
      let stream = try Stream(readFrom: fileURL)
      let reader = try Reader(format: format, stream: stream)
      let json = try reader.json()
      complete(result, with: json)
    } catch {
      // File has no C2PA data — return nil, not an error
      complete(result, with: nil)
    }
  }

  private func complete(_ result: @escaping FlutterResult, with value: Any?) {
    DispatchQueue.main.async {
      result(value)
    }
  }

  private func mimeType(for url: URL) -> String? {
    switch url.pathExtension.lowercased() {
    case "jpg", "jpeg":
      return "image/jpeg"
    case "png":
      return "image/png"
    case "webp":
      return "image/webp"
    case "tif", "tiff":
      return "image/tiff"
    case "heic":
      return "image/heic"
    case "mp4":
      return "video/mp4"
    case "mov":
      return "video/quicktime"
    default:
      return nil
    }
  }

  private func isVideo(_ url: URL) -> Bool {
    ["mp4", "mov"].contains(url.pathExtension.lowercased())
  }

  private func hasManifest(_ url: URL, format: String) -> Bool {
    do {
      let stream = try Stream(readFrom: url)
      let reader = try Reader(format: format, stream: stream)
      _ = try reader.json()
      return true
    } catch {
      return false
    }
  }

  // MARK: - Thumbnail

  /// Returns JPEG thumbnail data for the given media URL.
  /// Uses AVFoundation for video and CGImageSource for images.
  private func generateThumbnailData(for url: URL) -> Data? {
    if isVideo(url) {
      let asset = AVAsset(url: url)
      let generator = AVAssetImageGenerator(asset: asset)
      generator.appliesPreferredTrackTransform = true
      generator.maximumSize = CGSize(width: 512, height: 512)
      guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else {
        return nil
      }
      return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.85)
    } else {
      guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        return nil
      }
      let opts: [CFString: Any] = [
        kCGImageSourceThumbnailMaxPixelSize: 512,
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
      ]
      guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, opts as CFDictionary) else {
        return nil
      }
      return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.85)
    }
  }

  private func thumbnailForMedia(args: [String: Any], result: @escaping FlutterResult) {
    guard let path = args["path"] as? String else {
      complete(result, with: nil)
      return
    }
    let url = URL(fileURLWithPath: path)
    if let data = generateThumbnailData(for: url) {
      complete(result, with: FlutterStandardTypedData(bytes: data))
    } else {
      complete(result, with: nil)
    }
  }

  // MARK: - Manifest JSON builder

  private func buildManifestJSON(title: String, mimeType: String, hasThumbnail: Bool = false) -> String {
    // Escape title for safe JSON embedding
    let safeTitle = title
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return """
    {
      "claim_generator": "Perfect C2PA Mobile/1.0",
      "claim_generator_info": [{"name": "Perfect C2PA Mobile", "version": "1.0"}],
      "title": "\(safeTitle)",
      "format": "\(mimeType)",
      "assertions": [
        {
          "label": "c2pa.actions",
          "data": {
            "actions": [
              {
                "action": "c2pa.edited",
                "softwareAgent": "Perfect C2PA Mobile/1.0",
                "description": "Signed on mobile with Perfect C2PA"
              }
            ]
          }
        }
      ]\(hasThumbnail ? #","thumbnail":{"format":"image/jpeg","identifier":"thumbnail"}"# : "")
    }
    """
  }

  private func buildParentIngredientJSON(title: String, mimeType: String) -> String {
    let safeTitle = title
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return """
    {
      "title": "\(safeTitle)",
      "format": "\(mimeType)",
      "relationship": "parentOf"
    }
    """
  }
}


// MARK: - PHPickerViewControllerDelegate

@available(iOS 16, *)
extension C2paNativeHandler: PHPickerViewControllerDelegate {
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard let pendingResult = pendingPickResult else { return }
    pendingPickResult = nil

    guard let item = results.first else {
      // User cancelled — return nil (not an error).
      complete(pendingResult, with: nil)
      return
    }

    // Prefer the asset's native format to avoid any transcoding that would strip C2PA.
    // Images: try HEIC before JPEG so we never trigger a lossy conversion.
    let preferredTypes = [
      "public.heic", "public.heif",
      "public.jpeg",
      "public.png",
      "public.tiff",
      "org.webmproject.webp",
      "com.apple.quicktime-movie",
      "public.mpeg-4",
    ]
    let registered = item.itemProvider.registeredTypeIdentifiers
    let uti = preferredTypes.first { registered.contains($0) } ?? registered.first

    guard let uti else {
      complete(pendingResult, with: FlutterError(
        code: "UNSUPPORTED_TYPE",
        message: "No supported type found for selected item",
        details: registered.joined(separator: ", ")
      ))
      return
    }

    // loadFileRepresentation returns a COPY of the original binary; the temp URL
    // is valid only inside this closure so we copy it to our own temp file first.
    // Capture suggestedName before entering the async closure as a display-name fallback.
    let suggestedName = item.itemProvider.suggestedName
    item.itemProvider.loadFileRepresentation(forTypeIdentifier: uti) { [weak self] url, error in
      guard let self else { return }
      if let error {
        self.complete(pendingResult, with: FlutterError(
          code: "LOAD_FAILED",
          message: error.localizedDescription,
          details: "\(error)"
        ))
        return
      }
      guard let url else {
        self.complete(pendingResult, with: nil)
        return
      }
      // Prefer the original filename from the temp URL (e.g. "IMG_1234.heic").
      // Fall back to suggestedName (display name without extension) + ext.
      // Always ensure uniqueness to avoid collisions when the same file is picked twice.
      let ext = url.pathExtension
      let baseName: String = {
        let fromURL = url.deletingPathExtension().lastPathComponent
        // loadFileRepresentation may produce a UUID-style name on some iOS versions —
        // treat it as unhelpful if it looks like a UUID (32 hex chars + dashes).
        let looksLikeUUID = fromURL.count == 36 &&
          fromURL.filter({ $0 == "-" }).count == 4
        if !looksLikeUUID && !fromURL.isEmpty { return fromURL }
        return suggestedName ?? "media"
      }()
      // Strip filesystem-unsafe characters
      let safe = baseName
        .components(separatedBy: CharacterSet(charactersIn: ":/\\?*|\"<>"))
        .joined()
      let tmpDir = FileManager.default.temporaryDirectory
      let candidate = tmpDir.appendingPathComponent(safe).appendingPathExtension(ext)
      // If a file with this name already exists, append a short unique suffix.
      let dest: URL
      if FileManager.default.fileExists(atPath: candidate.path) {
        let suffix = UUID().uuidString.prefix(8)
        dest = tmpDir.appendingPathComponent("\(safe)_\(suffix)").appendingPathExtension(ext)
      } else {
        dest = candidate
      }
      do {
        try FileManager.default.copyItem(at: url, to: dest)
        self.complete(pendingResult, with: dest.path)
      } catch {
        self.complete(pendingResult, with: FlutterError(
          code: "COPY_FAILED",
          message: error.localizedDescription,
          details: "\(error)"
        ))
      }
    }
  }
}

private enum NativeC2paError: LocalizedError {
  case unsupportedWriteMode(String)
  case removalFailed(String)

  var errorDescription: String? {
    switch self {
    case .unsupportedWriteMode(let mode):
      return "Unsupported C2PA write mode: \(mode)"
    case .removalFailed(let reason):
      return "C2PA removal failed: \(reason)"
    }
  }
}
