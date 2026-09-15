// Copyright 2026 Perfect Collage.
//
// Minimal Swift bridge for the vendored C2PA C library. It deliberately covers
// only the APIs used by C2paNativeHandler, so the iOS target has no SwiftPM C2PA
// package or binary-artifact download at build time.

import C2PAC
import Foundation
import Security

enum C2PAError: Error, LocalizedError {
  case api(String)
  case invalidPointer
  case unsupportedSigningAlgorithm
  case keychain(String, OSStatus)
  case signing(Error?)

  var errorDescription: String? {
    switch self {
    case .api(let message): return "C2PA: \(message)"
    case .invalidPointer: return "C2PA returned an invalid pointer"
    case .unsupportedSigningAlgorithm: return "Unsupported C2PA signing algorithm"
    case .keychain(let tag, let status): return "Unable to find signing key \(tag): \(status)"
    case .signing(let error): return "Keychain signing failed\(error.map { ": \($0)" } ?? "")"
    }
  }
}

private func c2paError() -> String {
  guard let value = c2pa_error() else { return "Unknown C2PA error" }
  defer { c2pa_string_free(value) }
  return String(cString: value)
}

private func required<T>(_ pointer: UnsafeMutablePointer<T>?) throws -> UnsafeMutablePointer<T> {
  guard let pointer else { throw C2PAError.api(c2paError()) }
  return pointer
}

private func required(_ pointer: OpaquePointer?) throws -> OpaquePointer {
  guard let pointer else { throw C2PAError.api(c2paError()) }
  return pointer
}

private func successful(_ status: Int64) throws {
  if status < 0 { throw C2PAError.api(c2paError()) }
}

enum BuilderIntent {
  case create(DigitalSourceType)
  case edit

  var cValue: (C2paBuilderIntent, C2paDigitalSourceType) {
    switch self {
    case .create(let source): return (Create, source.cValue)
    case .edit: return (Edit, Empty)
    }
  }
}

enum DigitalSourceType {
  case digitalCreation

  var cValue: C2paDigitalSourceType {
    switch self {
    case .digitalCreation: return DigitalCreation
    }
  }
}

final class Stream {
  typealias Reader = (UnsafeMutableRawPointer, Int) -> Int
  typealias Seeker = (Int, C2paSeekMode) -> Int
  typealias Writer = (UnsafeRawPointer, Int) -> Int
  typealias Flusher = () -> Int

  private final class Provider {
    let read: Reader?
    let seek: Seeker?
    let write: Writer?
    let flush: Flusher?
    let retainedFile: FileHandle?

    init(read: Reader?, seek: Seeker?, write: Writer?, flush: Flusher?, retainedFile: FileHandle? = nil) {
      self.read = read
      self.seek = seek
      self.write = write
      self.flush = flush
      self.retainedFile = retainedFile
    }

    deinit { try? retainedFile?.close() }
  }

  private static let readCallback: ReadCallback = { context, bytes, length in
    guard let context, let bytes else { return -1 }
    let provider = Unmanaged<Provider>.fromOpaque(context).takeUnretainedValue()
    return provider.read?(bytes, Int(length)) ?? -1
  }

  private static let seekCallback: SeekCallback = { context, offset, mode in
    guard let context else { return -1 }
    let provider = Unmanaged<Provider>.fromOpaque(context).takeUnretainedValue()
    return provider.seek?(Int(offset), mode) ?? -1
  }

  private static let writeCallback: WriteCallback = { context, bytes, length in
    guard let context, let bytes else { return -1 }
    let provider = Unmanaged<Provider>.fromOpaque(context).takeUnretainedValue()
    return provider.write?(bytes, Int(length)) ?? -1
  }

  private static let flushCallback: FlushCallback = { context in
    guard let context else { return -1 }
    let provider = Unmanaged<Provider>.fromOpaque(context).takeUnretainedValue()
    return provider.flush?() ?? 0
  }

  private let retainedProvider: Unmanaged<Provider>
  fileprivate let raw: UnsafeMutablePointer<C2paStream>

  private init(_ provider: Provider) throws {
    retainedProvider = .passRetained(provider)
    let context = retainedProvider.toOpaque().assumingMemoryBound(to: StreamContext.self)
    raw = try required(c2pa_create_stream(
      context,
      provider.read == nil ? nil : Self.readCallback,
      provider.seek == nil ? nil : Self.seekCallback,
      provider.write == nil ? nil : Self.writeCallback,
      provider.flush == nil ? nil : Self.flushCallback
    ))
  }

  convenience init(readFrom url: URL) throws {
    let handle = try FileHandle(forReadingFrom: url)
    try self.init(Provider(
      read: { buffer, count in
        let data = (try? handle.read(upToCount: count)) ?? Data()
        data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: data.count)
        return data.count
      },
      seek: { offset, mode in
        do {
          let target: Int64
          switch mode {
          case Start: target = Int64(offset)
          case Current: target = Int64(handle.offsetInFile) + Int64(offset)
          case End: target = Int64(try handle.seekToEnd()) + Int64(offset)
          default: return -1
          }
          let position = UInt64(max(0, target))
          try handle.seek(toOffset: position)
          return Int(position)
        } catch { return -1 }
      },
      write: nil,
      flush: nil,
      retainedFile: handle
    ))
  }

  convenience init(writeTo url: URL) throws {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try self.init(Provider(
      read: nil,
      seek: { offset, mode in
        do {
          let target: Int64
          switch mode {
          case Start: target = Int64(offset)
          case Current: target = Int64(handle.offsetInFile) + Int64(offset)
          case End: target = Int64(try handle.seekToEnd()) + Int64(offset)
          default: return -1
          }
          let position = UInt64(max(0, target))
          try handle.seek(toOffset: position)
          return Int(position)
        } catch { return -1 }
      },
      write: { buffer, count in
        do {
          try handle.write(contentsOf: Data(bytes: buffer, count: count))
          return count
        } catch { return -1 }
      },
      flush: { (try? handle.synchronize()) == nil ? -1 : 0 },
      retainedFile: handle
    ))
  }

  deinit {
    c2pa_release_stream(raw)
    retainedProvider.release()
  }
}

enum SigningAlgorithm {
  case es256

  fileprivate var cValue: C2paSigningAlg { Es256 }
  fileprivate var secKeyAlgorithm: SecKeyAlgorithm { .ecdsaSignatureMessageX962SHA256 }
}

final class Signer {
  fileprivate let raw: OpaquePointer
  private var retainedContext: Unmanaged<AnyObject>?

  init(algorithm: SigningAlgorithm, certificateChainPEM: String, tsa: URL?, keychainKeyTag: String) throws {
    final class CallbackBox {
      let sign: (Data) throws -> Data
      init(_ sign: @escaping (Data) throws -> Data) { self.sign = sign }
    }

    let secAlgorithm = algorithm.secKeyAlgorithm
    let callback = CallbackBox { data in
      let query: [String: Any] = [
        kSecClass as String: kSecClassKey,
        kSecAttrApplicationTag as String: keychainKeyTag,
        kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        kSecReturnRef as String: true,
      ]
      var item: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &item)
      guard status == errSecSuccess, let key = item as! SecKey? else {
        throw C2PAError.keychain(keychainKeyTag, status)
      }
      guard SecKeyIsAlgorithmSupported(key, .sign, secAlgorithm) else {
        throw C2PAError.unsupportedSigningAlgorithm
      }
      var error: Unmanaged<CFError>?
      guard let signature = SecKeyCreateSignature(key, secAlgorithm, data as CFData, &error) else {
        throw C2PAError.signing(error?.takeRetainedValue())
      }
      return signature as Data
    }
    let context = Unmanaged.passRetained(callback as AnyObject)
    let trampoline: SignerCallback = { context, data, length, output, capacity in
      guard let context, let data, let output else { return -1 }
      let callback = Unmanaged<CallbackBox>.fromOpaque(UnsafeMutableRawPointer(mutating: context)).takeUnretainedValue()
      do {
        let signature = try callback.sign(Data(bytes: data, count: Int(length)))
        guard signature.count <= Int(capacity) else { return -1 }
        signature.copyBytes(to: output, count: signature.count)
        return signature.count
      } catch { return -1 }
    }
    let signer = try certificateChainPEM.withCString { certificate in
      try tsa?.absoluteString.withCString { tsaValue in
        try required(c2pa_signer_create(context.toOpaque(), trampoline, algorithm.cValue, certificate, tsaValue))
      } ?? required(c2pa_signer_create(context.toOpaque(), trampoline, algorithm.cValue, certificate, nil))
    }
    raw = signer
    retainedContext = context
  }

  deinit {
    c2pa_signer_free(raw)
    retainedContext?.release()
  }
}

final class Builder {
  private let raw: UnsafeMutablePointer<C2paBuilder>

  init(manifestJSON: String) throws { raw = try required(c2pa_builder_from_json(manifestJSON)) }
  deinit { c2pa_builder_free(raw) }

  func setIntent(_ intent: BuilderIntent) throws {
    let (kind, source) = intent.cValue
    try successful(Int64(c2pa_builder_set_intent(raw, kind, source)))
  }

  func addIngredient(json: String, format: String, from stream: Stream) throws {
    try successful(Int64(c2pa_builder_add_ingredient_from_stream(raw, json, format, stream.raw)))
  }

  func addResource(uri: String, stream: Stream) throws {
    try successful(Int64(c2pa_builder_add_resource(raw, uri, stream.raw)))
  }

  @discardableResult
  func sign(format: String, source: Stream, destination: Stream, signer: Signer) throws -> Data {
    var manifest: UnsafePointer<UInt8>?
    let length = c2pa_builder_sign(raw, format, source.raw, destination.raw, signer.raw, &manifest)
    try successful(length)
    guard let manifest else { return Data() }
    defer { c2pa_manifest_bytes_free(manifest) }
    return Data(bytes: manifest, count: Int(length))
  }
}

final class Reader {
  private let raw: UnsafeMutablePointer<C2paReader>

  init(format: String, stream: Stream) throws {
    raw = try required(c2pa_reader_from_stream(format, stream.raw))
  }

  deinit { c2pa_reader_free(raw) }

  func json() throws -> String {
    guard let value = c2pa_reader_json(raw) else { throw C2PAError.api(c2paError()) }
    defer { c2pa_string_free(value) }
    return String(cString: value)
  }
}
