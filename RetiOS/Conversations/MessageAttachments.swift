import Foundation
import LXMF

/// Renderable view of the LXMF `fields` carried by an inbound message.
///
/// LXMF messages can carry structured attachments alongside their text, keyed
/// by the `Field` IDs (mirrors `LXMF/LXMF.py`). Until the C1 fix, inbound
/// `fields` were dropped on `unpack`; now they survive, so RetiOS can surface
/// them. We decode them lazily from the stored packed bytes rather than holding
/// a second copy of the (loosely-typed) `[Int: Any]` dictionary in SwiftData.
///
/// Field value shapes (after `LXMessage.unpack`, see `decodeFieldValue`):
///   - `FIELD_IMAGE`            (0x06): `[image_type, image_bytes]`
///   - `FIELD_FILE_ATTACHMENTS` (0x05): `[[file_name, file_bytes], …]`
///   - `FIELD_AUDIO`            (0x07): `[audio_mode, audio_bytes]`
///   - `FIELD_TELEMETRY`        (0x02): msgpacked telemetry blob (opaque here)
struct MessageAttachments {
    struct ImageAttachment { let type: String; let data: Data }
    struct FileAttachment { let name: String; let data: Data }
    struct AudioAttachment { let mode: Int; let data: Data }

    var image: ImageAttachment?
    var files: [FileAttachment] = []
    var audio: AudioAttachment?
    /// Size in bytes of a telemetry blob, if present (we don't parse the
    /// Sideband-specific telemetry payload — just acknowledge it).
    var telemetryBytes: Int?

    /// True when the message carried nothing beyond text we can't display here.
    var isEmpty: Bool {
        image == nil && files.isEmpty && audio == nil && telemetryBytes == nil
    }

    /// Decode the attachments from a message's raw packed bytes. Returns `nil`
    /// when the bytes can't be unpacked or carry no recognised attachment.
    static func decode(from packed: Data) -> MessageAttachments? {
        guard let msg = try? LXMessage.unpack(packed) else { return nil }
        let fields = msg.fields
        guard !fields.isEmpty else { return nil }

        var result = MessageAttachments()

        // FIELD_IMAGE: [type, bytes]
        if let raw = fields[Int(Field.image.rawValue)], case let pair as [Any] = raw,
           pair.count >= 2, let data = asData(pair[1]) {
            result.image = ImageAttachment(type: asString(pair[0]) ?? "image", data: data)
        }

        // FIELD_FILE_ATTACHMENTS: [[name, bytes], …]
        if let raw = fields[Int(Field.fileAttachments.rawValue)], case let list as [Any] = raw {
            for entry in list {
                guard case let pair as [Any] = entry, pair.count >= 2,
                      let data = asData(pair[1]) else { continue }
                let name = asString(pair[0]) ?? "attachment"
                result.files.append(FileAttachment(name: name, data: data))
            }
        }

        // FIELD_AUDIO: [mode, bytes]
        if let raw = fields[Int(Field.audio.rawValue)], case let pair as [Any] = raw,
           pair.count >= 2, let data = asData(pair[1]) {
            result.audio = AudioAttachment(mode: asInt(pair[0]) ?? 0, data: data)
        }

        // FIELD_TELEMETRY: opaque blob — record its presence/size only.
        if let raw = fields[Int(Field.telemetry.rawValue)], let data = asData(raw) {
            result.telemetryBytes = data.count
        }

        return result.isEmpty ? nil : result
    }

    // MARK: - Loose value coercion
    //
    // Field values come back as `Data` (msgpack bin), `String` (msgpack str),
    // or `Int`. Different senders pack names/types as either str or bin, so we
    // accept both throughout.

    private static func asData(_ v: Any) -> Data? {
        if let d = v as? Data { return d }
        if let s = v as? String { return s.data(using: .utf8) }
        return nil
    }

    private static func asString(_ v: Any) -> String? {
        if let s = v as? String { return s }
        if let d = v as? Data { return String(data: d, encoding: .utf8) }
        return nil
    }

    private static func asInt(_ v: Any) -> Int? {
        if let i = v as? Int { return i }
        if let u = v as? UInt64 { return Int(exactly: u) }
        return nil
    }
}
