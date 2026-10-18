public import CryptoKit
public import Foundation

/// OpenSSH wire encoding and SSHSIG protocol implementation (RFC 4251, RFC 5656, PROTOCOL.sshsig).
public enum SSHSIG {
  public static let magic = "SSHSIG"
  public static let keyType = "ecdsa-sha2-nistp256"
  public static let curveName = "nistp256"
  public static let defaultHashAlgorithm = "sha512"

  // MARK: - Wire Encoding Helpers

  public static func writeString(_ str: String, to data: inout Data) {
    var len = UInt32(str.utf8.count).bigEndian
    data.append(Data(bytes: &len, count: 4))
    data.append(contentsOf: str.utf8)
  }

  public static func writeBytes(_ bytes: Data, to data: inout Data) {
    var len = UInt32(bytes.count).bigEndian
    data.append(Data(bytes: &len, count: 4))
    data.append(bytes)
  }

  public static func formatMPInt(_ bytes: Data) -> Data {
    var formatted = Data()
    if let first = bytes.first, first & 0x80 != 0 {
      formatted.append(0x00)
    }
    formatted.append(bytes)
    return formatted
  }

  // MARK: - Public Key Formatting

  /// Formats a P-256 public key into OpenSSH wire format data.
  public static func encodePublicKeyWire(_ publicKey: P256.Signing.PublicKey) -> Data {
    var wire = Data()
    writeString(keyType, to: &wire)
    writeString(curveName, to: &wire)
    let point = Data([0x04]) + publicKey.rawRepresentation
    writeBytes(point, to: &wire)
    return wire
  }

  public static func formatOpenSSHPublicKey(
    _ publicKey: P256.Signing.PublicKey,
    comment: String = "invariants-owner"
  ) -> String {
    let wire = encodePublicKeyWire(publicKey)
    let b64 = wire.base64EncodedString()
    return "\(keyType) \(b64) \(comment)\n"
  }

  // MARK: - Signed Data Payload

  /// Builds the exact payload hashed and passed to the ECDSA signing operation per PROTOCOL.sshsig.
  public static func buildSignedData(
    messageData: Data,
    namespace: String = "invariants",
    hashAlgorithm: String = defaultHashAlgorithm
  ) -> Data {
    var payload = Data(magic.utf8)
    writeString(namespace, to: &payload)
    writeString("", to: &payload)  // reserved
    writeString(hashAlgorithm, to: &payload)

    let hashedMessage: Data
    if hashAlgorithm == "sha256" {
      hashedMessage = Data(SHA256.hash(data: messageData))
    } else {
      hashedMessage = Data(SHA512.hash(data: messageData))
    }
    writeBytes(hashedMessage, to: &payload)
    return payload
  }

  // MARK: - Signature Envelope

  /// Wraps an ECDSA P-256 signature (raw 64-byte r || s) and public key into an armored OpenSSH signature.
  public static func buildArmoredSignature(
    rawSignature: Data,
    publicKey: P256.Signing.PublicKey,
    namespace: String = "invariants",
    hashAlgorithm: String = defaultHashAlgorithm
  ) -> String {
    let rBytes = rawSignature.prefix(32)
    let sBytes = rawSignature.suffix(32)

    var rsWire = Data()
    writeBytes(formatMPInt(rBytes), to: &rsWire)
    writeBytes(formatMPInt(sBytes), to: &rsWire)

    var sigBlob = Data()
    writeString(keyType, to: &sigBlob)
    writeBytes(rsWire, to: &sigBlob)

    let pkWire = encodePublicKeyWire(publicKey)

    var envelope = Data(magic.utf8)
    var version = UInt32(1).bigEndian
    envelope.append(Data(bytes: &version, count: 4))
    writeBytes(pkWire, to: &envelope)
    writeString(namespace, to: &envelope)
    writeString("", to: &envelope)  // reserved
    writeString(hashAlgorithm, to: &envelope)
    writeBytes(sigBlob, to: &envelope)

    let b64 = envelope.base64EncodedString()
    var armored = "-----BEGIN SSH SIGNATURE-----\n"
    var str = b64
    while !str.isEmpty {
      let take = min(76, str.count)
      let chunk = str.prefix(take)
      armored += String(chunk) + "\n"
      str = String(str.dropFirst(take))
    }
    armored += "-----END SSH SIGNATURE-----\n"
    return armored
  }
}
