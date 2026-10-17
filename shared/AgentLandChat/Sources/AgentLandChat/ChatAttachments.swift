import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import AgentLandBranding
import AgentLandDesign
import AgentLandCore

/// What a chat message may carry, matching the host's upload limits.
public enum ChatAttachmentPolicy {
    public static let maxCount = 5
    public static let maxFileBytes = 10 << 20
    public static let maxTextBytes = 2 << 20
    public static let maxImagePixels = 2048

    public struct Prepared: Equatable, Sendable {
        public let name: String
        public let mime: String
        public let data: Data
    }

    public enum Problem: LocalizedError, Equatable {
        case unsupported(String)
        case tooLarge(String)
        case unreadable(String)
        public var errorDescription: String? {
            switch self {
            case let .unsupported(name): "\(name) can't be attached. Use an image, PDF, or text file."
            case let .tooLarge(name): "\(name) is too large to attach."
            case let .unreadable(name): "\(name) couldn't be read."
            }
        }
    }

    /// Images are re-encoded, which also drops location and other metadata, and
    /// scaled to at most 2048 px. Text must be UTF-8. Other types are refused.
    public static func prepare(name: String, data: Data, type: UTType?) throws -> Prepared {
        let name = sanitizedName(name)
        let type = type ?? UTType(filenameExtension: (name as NSString).pathExtension)
        guard !data.isEmpty else { throw Problem.unreadable(name) }
        if let type, type.conforms(to: .image) {
            if type.conforms(to: .gif) {
                guard data.count <= maxFileBytes else { throw Problem.tooLarge(name) }
                return Prepared(name: name, mime: "image/gif", data: data)
            }
            let keepPNG = type.conforms(to: .png)
            guard let encoded = reencodedImage(data, png: keepPNG) else { throw Problem.unreadable(name) }
            guard encoded.count <= maxFileBytes else { throw Problem.tooLarge(name) }
            let base = (name as NSString).deletingPathExtension
            return Prepared(name: (base.isEmpty ? "Image" : base) + (keepPNG ? ".png" : ".jpg"),
                            mime: keepPNG ? "image/png" : "image/jpeg", data: encoded)
        }
        if let type, type.conforms(to: .pdf) {
            guard data.count <= maxFileBytes else { throw Problem.tooLarge(name) }
            return Prepared(name: name, mime: "application/pdf", data: data)
        }
        let textMime: String?
        if let type, type.conforms(to: .json) { textMime = "application/json" }
        else if let type, type.conforms(to: .commaSeparatedText) { textMime = "text/csv" }
        else if let type, type.identifier == "net.daringfireball.markdown" || ["md", "markdown"].contains(type.preferredFilenameExtension ?? "") { textMime = "text/markdown" }
        else if let type, type.conforms(to: .text) || type.conforms(to: .sourceCode) { textMime = "text/plain" }
        else if type == nil || type?.isDynamic == true || type == .data { textMime = "text/plain" } // e.g. Makefile, .env.example
        else { textMime = nil }
        guard let mime = textMime else { throw Problem.unsupported(name) }
        guard String(data: data, encoding: .utf8) != nil else { throw Problem.unsupported(name) }
        guard data.count <= maxTextBytes else { throw Problem.tooLarge(name) }
        return Prepared(name: name, mime: mime, data: data)
    }

    /// Reads a picked or dropped file, checking its size before loading it.
    public static func prepare(fileAt url: URL) throws -> Prepared {
        let name = url.lastPathComponent
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .isRegularFileKey])
        guard values?.isRegularFile != false else { throw Problem.unsupported(name) }
        if let size = values?.fileSize, size > maxFileBytes * 3 { throw Problem.tooLarge(name) }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw Problem.unreadable(name) }
        return try prepare(name: name, data: data, type: values?.contentType)
    }

    public static func sanitizedName(_ name: String) -> String {
        let cleaned = name.unicodeScalars.map { scalar -> String in
            if CharacterSet.controlCharacters.contains(scalar) || scalar == "/" || scalar == ":" || scalar == "\\" { return "_" }
            return String(scalar)
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        var result = ""
        for character in cleaned where result.utf8.count + String(character).utf8.count <= 120 { result.append(character) }
        return result.isEmpty ? "Attachment" : result
    }

    public static func symbol(forMime mime: String) -> String {
        if mime.hasPrefix("image/") { return "photo" }
        if mime == "application/pdf" { return "doc.richtext" }
        return "doc.text"
    }

    static func reencodedImage(_ data: Data, png: Bool) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxImagePixels
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        let format = png ? UTType.png : UTType.jpeg
        guard let destination = CGImageDestinationCreateWithData(output, format.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, png ? nil : [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    static func thumbnail(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 180
        ] as CFDictionary)
    }
}

public struct ChatPendingAttachment: Identifiable {
    public enum Upload: Equatable { case uploading, uploaded(String), failed(String) }
    public let id = UUID()
    public let name: String
    public let mime: String
    public let size: Int
    public let thumbnail: CGImage?
    public var upload: Upload = .uploading
}

/// Files picked for the next message. Each uploads as soon as it is added; the
/// message can be sent once every file has an upload id. A failed upload is
/// tried again only when the person taps Upload Again.
@MainActor @Observable
public final class ChatAttachmentTray {
    public typealias Uploader = @MainActor (ChatAttachmentPolicy.Prepared) async throws -> UploadedAttachment
    public private(set) var items: [ChatPendingAttachment] = []
    public var problem: String?
    @ObservationIgnored private var sources: [UUID: (prepared: ChatAttachmentPolicy.Prepared, upload: Uploader)] = [:]

    public init() {}

    public var uploadedIDs: [String]? {
        let ids = items.compactMap { item -> String? in
            if case let .uploaded(id) = item.upload { return id }
            return nil
        }
        return ids.count == items.count ? ids : nil
    }
    public var isEmpty: Bool { items.isEmpty }
    public var remaining: Int { max(0, ChatAttachmentPolicy.maxCount - items.count) }
    public var uploading: Bool { items.contains { $0.upload == .uploading } }

    public func add(_ prepared: ChatAttachmentPolicy.Prepared, upload: @escaping Uploader) {
        guard remaining > 0 else {
            problem = "Attach up to \(ChatAttachmentPolicy.maxCount) files per message."
            return
        }
        let item = ChatPendingAttachment(name: prepared.name, mime: prepared.mime, size: prepared.data.count,
                                         thumbnail: prepared.mime.hasPrefix("image/") ? ChatAttachmentPolicy.thumbnail(prepared.data) : nil)
        items.append(item)
        sources[item.id] = (prepared, upload)
        start(item.id)
    }

    /// Uploads a failed file again, because the person asked.
    public func uploadAgain(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), case .failed = items[index].upload else { return }
        items[index].upload = .uploading
        start(id)
    }

    private func start(_ id: UUID) {
        guard let source = sources[id] else { return }
        Task {
            let result: ChatPendingAttachment.Upload
            do { result = .uploaded(try await source.upload(source.prepared).id) }
            catch { result = .failed(error.localizedDescription) }
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            items[index].upload = result
            if case .uploaded = result { sources[id] = nil }
        }
    }

    public func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        sources[id] = nil
    }
    /// Drops files that went out with a message, keeping any added meanwhile.
    public func removeSent(_ ids: [String]) {
        items.removeAll { item in
            if case let .uploaded(id) = item.upload { return ids.contains(id) }
            return false
        }
    }
    public func clear() { items.removeAll(); sources.removeAll(); problem = nil }
}

public struct ChatPendingAttachmentsStrip: View {
    let tray: ChatAttachmentTray
    @ScaledMetric(relativeTo: .body) private var tileSize: CGFloat = 58
    @ScaledMetric(relativeTo: .body) private var fileWidth: CGFloat = 132
    public init(tray: ChatAttachmentTray) { self.tray = tray }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tray.items) { tile($0) }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
        }
        .accessibilityIdentifier("chatPendingAttachments")
    }

    private func tile(_ item: ChatPendingAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumbnail = item.thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(width: tileSize, height: tileSize)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: ChatAttachmentPolicy.symbol(forMime: item.mime))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name).lineLimit(1).truncationMode(.middle)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))
                                .foregroundStyle(AgentLandColor.textSecondary.color)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(AgentLandColor.text.color)
                    .padding(.horizontal, 8)
                    .frame(width: fileWidth, height: tileSize, alignment: .leading)
                    .background(AgentLandColor.surface.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            .overlay {
                switch item.upload {
                case .uploading:
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(AgentLandColor.canvas.color.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                case .failed:
                    Button { tray.uploadAgain(item.id) } label: {
                        Label("Upload Again", systemImage: "exclamationmark.arrow.circlepath")
                            .labelStyle(.iconOnly)
                            .font(.title3)
                            .foregroundStyle(AgentLandColor.danger.color)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(AgentLandColor.canvas.color.opacity(0.8), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Upload \(item.name) Again")
                    .accessibilityIdentifier("chatUploadAgain")
                case .uploaded:
                    EmptyView()
                }
            }
            Button { tray.remove(item.id) } label: {
                Image(systemName: "xmark.circle.fill")
                    #if os(iOS)
                    // The system's two-level remove symbol (CH-18).
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(AgentLandColor.text.color)
                    #else
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(AgentLandColor.canvas.color, AgentLandColor.text.color)
                    #endif
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .offset(x: 16, y: -16)
            .accessibilityLabel("Remove \(item.name)")
        }
        .padding(.top, 14)
        .padding(.trailing, 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibility(item))
    }

    private func accessibility(_ item: ChatPendingAttachment) -> String {
        switch item.upload {
        case .uploading: "\(item.name), uploading"
        case .uploaded: item.name
        case let .failed(reason): "\(item.name), not uploaded. \(reason)"
        }
    }
}
