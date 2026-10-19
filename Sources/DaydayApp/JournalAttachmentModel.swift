import AppKit
import DaydayCore
import DaydayStorage
import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class JournalAttachmentModel: ObservableObject {
  @Published private(set) var attachments: [JournalAttachment] = []
  @Published private(set) var images: [JournalAttachmentID: NSImage] = [:]
  @Published private(set) var imageResources: [JournalAttachmentID: Data] = [:]
  @Published private(set) var status = "图片附件尚未连接本地存储"

  private var repository: (any JournalAttachmentRepository)?
  private var fileStore: JournalAttachmentFileStore?
  private weak var journal: JournalEntryModel?
  private var reloadGeneration = 0
  private let imageCache: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 64
    cache.totalCostLimit = 128 * 1_024 * 1_024
    return cache
  }()

  func configure(
    repository: any JournalAttachmentRepository,
    fileStore: JournalAttachmentFileStore,
    journal: JournalEntryModel
  ) {
    self.repository = repository
    self.fileStore = fileStore
    self.journal = journal
    Task { await reloadForSelectedDay() }
  }

  @discardableResult
  func importImage(from sourceURL: URL) async -> JournalAttachment? {
    guard let repository, let fileStore, let journal else {
      status = "本地存储尚未就绪"
      return nil
    }
    let accessed = sourceURL.startAccessingSecurityScopedResource()
    defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
    var storedKey: JournalRelativeFileKey?
    do {
      let prepared = try await Task.detached(priority: .userInitiated) {
        try JournalImageImport.prepare(sourceURL)
      }.value
      guard let displayImage = NSImage(data: prepared.display.data) else {
        throw JournalAttachmentFileStore.StoreError.unavailable
      }
      let anchor = try await journal.attachmentAnchor()
      let key = try await fileStore.storeImage(
        data: prepared.data, fileExtension: prepared.fileExtension)
      storedKey = key
      let attachment = try JournalAttachment(
        journalEntryID: anchor.entryID,
        dayID: anchor.dayID,
        payload: .image(
          try JournalImageAttachment(
            relativeFileKey: key,
            mediaType: prepared.mediaType,
            pixelWidth: prepared.pixelWidth,
            pixelHeight: prepared.pixelHeight,
            byteCount: prepared.data.count
          )
        ),
        createdAt: .now
      )
      _ = try await repository.insert(attachment)
      images[attachment.id] = displayImage
      imageResources[attachment.id] = prepared.display.data
      imageCache.setObject(
        displayImage,
        forKey: attachment.id.rawValue.uuidString as NSString,
        cost: prepared.display.decodedByteCost
      )
      attachments.append(attachment)
      status = "图片已导入，正在插入正文"
      return attachment
    } catch JournalAttachmentFileStore.StoreError.fileTooLarge {
      if let storedKey { try? await fileStore.discard(storedKey) }
      status = "图片超过 50 MB，未导入"
      return nil
    } catch {
      if let storedKey { try? await fileStore.discard(storedKey) }
      status = "无法导入这张图片"
      return nil
    }
  }

  func image(for attachment: JournalAttachment) -> NSImage? { images[attachment.id] }
  func image(for id: JournalAttachmentID) -> NSImage? { images[id] }

  func remove(_ attachment: JournalAttachment) async {
    guard let repository, let fileStore else { status = "本地存储尚未就绪"; return }
    do {
      try await repository.remove(attachment)
      if case .image(let image) = attachment.payload {
        try? await fileStore.discard(image.relativeFileKey)
      }
      attachments.removeAll { $0.id == attachment.id }
      images[attachment.id] = nil
      imageResources[attachment.id] = nil
      imageCache.removeObject(forKey: attachment.id.rawValue.uuidString as NSString)
      journal?.removeImageReference(attachment.id)
      status = "图片已从日记与本机附件库删除"
    } catch {
      status = "无法删除这张图片；原内容未改变"
    }
  }

  /// Copies the image bytes that are referenced by an exported Markdown file.
  /// The caller owns the export directory; Dayday never creates a backup or
  /// transfers journal media without an explicit save-panel action.
  func copyImageResources(to directory: URL) async throws -> [JournalAttachmentID: String] {
    guard let fileStore else { throw ExportError.storageUnavailable }
    let manager = FileManager.default
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    var paths: [JournalAttachmentID: String] = [:]

    for attachment in attachments {
      guard case .image(let image) = attachment.payload else { continue }
      let source = try await fileStore.url(for: image.relativeFileKey)
      let relativePath = image.relativeFileKey.rawValue
      let destination = directory.appendingPathComponent(relativePath, isDirectory: false)
      try manager.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      guard !manager.fileExists(atPath: destination.path) else {
        throw ExportError.destinationAlreadyExists
      }
      try manager.copyItem(at: source, to: destination)
      paths[attachment.id] = relativePath
    }
    return paths
  }

  func reloadForSelectedDay() async {
    guard let repository, let fileStore, let journal else { return }
    reloadGeneration &+= 1
    let generation = reloadGeneration
    let targetDayID = journal.selectedDay?.id
    do {
      let anchor = try await journal.attachmentAnchor()
      let attachments = try await repository.attachments(for: anchor.dayID)
      var loaded: [JournalAttachmentID: NSImage] = [:]
      var loadedResources: [JournalAttachmentID: Data] = [:]
      var imageFiles: [(id: JournalAttachmentID, url: URL)] = []
      for attachment in attachments {
        guard case .image(let image) = attachment.payload else { continue }
        let cacheKey = attachment.id.rawValue.uuidString as NSString
        if let cached = imageCache.object(forKey: cacheKey) {
          loaded[attachment.id] = cached
          if let resource = imageResources[attachment.id] {
            loadedResources[attachment.id] = resource
          } else if let url = try? await fileStore.url(for: image.relativeFileKey) {
            imageFiles.append((attachment.id, url))
          }
        } else if let url = try? await fileStore.url(for: image.relativeFileKey) {
          imageFiles.append((attachment.id, url))
        }
      }
      let displayResources = await Task.detached(priority: .utility) {
        imageFiles.compactMap { item -> (JournalAttachmentID, JournalImageImport.DisplayResource)? in
          guard let resource = try? JournalImageImport.displayResource(at: item.url) else {
            return nil
          }
          return (item.id, resource)
        }
      }.value
      for (id, resource) in displayResources {
        guard let nativeImage = NSImage(data: resource.data) else { continue }
        loaded[id] = nativeImage
        loadedResources[id] = resource.data
        imageCache.setObject(
          nativeImage,
          forKey: id.rawValue.uuidString as NSString,
          cost: resource.decodedByteCost
        )
      }
      guard generation == reloadGeneration,
        journal.selectedDay?.id == anchor.dayID || journal.selectedDay == nil
      else { return }
      self.attachments = attachments
      images = loaded
      imageResources = loadedResources
      status = attachments.isEmpty ? "还没有本地图片" : "图片仅保存在本机"
    } catch {
      guard generation == reloadGeneration, journal.selectedDay?.id == targetDayID else { return }
      attachments = []
      images = [:]
      imageResources = [:]
      status = "读取本地图片失败"
    }
  }

  enum ExportError: LocalizedError {
    case storageUnavailable
    case destinationAlreadyExists

    var errorDescription: String? {
      switch self {
      case .storageUnavailable: "本地图片存储尚未就绪"
      case .destinationAlreadyExists: "导出目标中已存在同名图片"
      }
    }
  }
}

enum JournalImageImport {
  private static let maximumDisplayPixelSize = 1_600

  struct DisplayResource: Sendable {
    let data: Data
    let pixelWidth: Int
    let pixelHeight: Int

    var decodedByteCost: Int {
      let (pixels, overflowed) = pixelWidth.multipliedReportingOverflow(by: pixelHeight)
      guard !overflowed else { return Int.max }
      let (bytes, byteOverflowed) = pixels.multipliedReportingOverflow(by: 4)
      return byteOverflowed ? Int.max : bytes
    }
  }

  struct Prepared: Sendable {
    let data: Data
    let mediaType: JournalImageMediaType
    let fileExtension: String
    let pixelWidth: Int
    let pixelHeight: Int
    let displayName: String
    let display: DisplayResource
  }

  static func prepare(_ url: URL) throws -> Prepared {
    let extensionValue = url.pathExtension.lowercased()
    let mediaType: JournalImageMediaType
    switch extensionValue {
    case "jpg", "jpeg": mediaType = .jpeg
    case "png": mediaType = .png
    case "heic": mediaType = .heic
    case "webp": mediaType = .webp
    default: throw JournalAttachmentFileStore.StoreError.unsafeFileName
    }
    let values = try url.resourceValues(forKeys: [.fileSizeKey])
    guard (values.fileSize ?? 0) <= JournalAttachmentFileStore.maximumImageByteCount else {
      throw JournalAttachmentFileStore.StoreError.fileTooLarge
    }
    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { throw JournalAttachmentFileStore.StoreError.unavailable }
    guard width > 0, height > 0 else { throw JournalAttachmentFileStore.StoreError.unavailable }
    let display = try makeDisplayResource(source: source)
    return Prepared(
      data: data,
      mediaType: mediaType,
      fileExtension: extensionValue,
      pixelWidth: width,
      pixelHeight: height,
      displayName: url.deletingPathExtension().lastPathComponent,
      display: display
    )
  }

  static func displayResource(at url: URL) throws -> DisplayResource {
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
      throw JournalAttachmentFileStore.StoreError.unavailable
    }
    return try makeDisplayResource(source: source)
  }

  private static func makeDisplayResource(source: CGImageSource) throws -> DisplayResource {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maximumDisplayPixelSize,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      throw JournalAttachmentFileStore.StoreError.unavailable
    }
    let encoded = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      encoded,
      UTType.png.identifier as CFString,
      1,
      nil
    ) else { throw JournalAttachmentFileStore.StoreError.unavailable }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw JournalAttachmentFileStore.StoreError.unavailable
    }
    return DisplayResource(
      data: encoded as Data,
      pixelWidth: image.width,
      pixelHeight: image.height
    )
  }
}
