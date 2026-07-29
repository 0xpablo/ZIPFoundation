//
//  RemoteArchive.swift
//  ZIPFoundation
//
//  Copyright © 2017-2025 Thomas Zoechling, https://www.peakstep.com and the ZIP Foundation project authors.
//  Released under the MIT License.
//
//  See https://github.com/weichsel/ZIPFoundation/blob/master/LICENSE for license information.
//

#if swift(>=5.5)

import Foundation

/// An asynchronous random-access source for ZIP data (e.g. HTTP Range).
@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
public protocol AsyncArchiveByteSource: Sendable {
    /// Total size of the archive in bytes.
    var size: UInt64 { get }

    /// Reads up to `length` bytes starting at `offset`.
    ///
    /// Intended for small, latency-sensitive reads (e.g. EOCD scan window, local header fixed fields).
    func read(offset: UInt64, length: Int) async throws -> Data

    /// Streams `length` bytes starting at `offset` as chunks.
    ///
    /// Intended for large reads (e.g. entry data) where implementations should ideally perform a single request and
    /// yield received bytes incrementally.
    func stream(offset: UInt64, length: Int, chunkSize: Int) async throws -> AsyncThrowingStream<Data, Error>
}

/// An async ZIP reader optimized for range-backed/network sources.
///
/// `RemoteArchive` fetches the End of Central Directory (EOCD) scan window and the Central Directory (CD) to provide
/// entry lookup/listing without reading Local File Headers. Entry extraction streams compressed bytes and decompresses
/// them on the fly.
@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
public struct RemoteArchive {
    public typealias CentralDirectoryEntry = Archive.CentralDirectoryEntry

    private let source: any AsyncArchiveByteSource
    private let pathEncoding: String.Encoding?

    private let endOfCentralDirectoryRecord: Archive.EndOfCentralDirectoryRecord
    private let zip64EndOfCentralDirectory: Archive.ZIP64EndOfCentralDirectory?

    public let centralDirectoryEntries: [CentralDirectoryEntry]

    public var totalNumberOfEntriesInCentralDirectory: UInt64 {
        zip64EndOfCentralDirectory?.record.totalNumberOfEntriesInCentralDirectory
        ?? UInt64(endOfCentralDirectoryRecord.totalNumberOfEntriesInCentralDirectory)
    }

    public var sizeOfCentralDirectory: UInt64 {
        zip64EndOfCentralDirectory?.record.sizeOfCentralDirectory
        ?? UInt64(endOfCentralDirectoryRecord.sizeOfCentralDirectory)
    }

    public var offsetToStartOfCentralDirectory: UInt64 {
        zip64EndOfCentralDirectory?.record.offsetToStartOfCentralDirectory
        ?? UInt64(endOfCentralDirectoryRecord.offsetToStartOfCentralDirectory)
    }

    public init(source: any AsyncArchiveByteSource, pathEncoding: String.Encoding? = nil) async throws {
        self.source = source
        self.pathEncoding = pathEncoding

        let archiveSize = source.size
        guard archiveSize >= UInt64(minEndOfCentralDirectoryOffset) else {
            throw Archive.ArchiveError.missingEndOfCentralDirectoryRecord
        }

        let tailLength = Int(Swift.min(UInt64(maxDirectoryEndOffset), archiveSize))
        let tailOffset = archiveSize - UInt64(tailLength)
        let tailData = try await RemoteArchive.readExactly(
            source: source,
            offset: tailOffset,
            length: tailLength
        )

        guard let (eocd, eocdOffset) = Archive.scanForEndOfCentralDirectoryRecord(in: tailData,
                                                                                  dataOffset: tailOffset,
                                                                                  fileSize: archiveSize) else {
            throw Archive.ArchiveError.missingEndOfCentralDirectoryRecord
        }
        self.endOfCentralDirectoryRecord = eocd
        let zip64 = try await RemoteArchive.scanForZIP64EndOfCentralDirectory(
            source: source,
            fileSize: archiveSize,
            eocdOffset: eocdOffset,
            tailData: tailData,
            tailOffset: tailOffset
        )
        self.zip64EndOfCentralDirectory = zip64

        let entryCount = zip64?.record.totalNumberOfEntriesInCentralDirectory
        ?? UInt64(eocd.totalNumberOfEntriesInCentralDirectory)
        let cdSize = zip64?.record.sizeOfCentralDirectory
        ?? UInt64(eocd.sizeOfCentralDirectory)
        let cdOffset = zip64?.record.offsetToStartOfCentralDirectory
        ?? UInt64(eocd.offsetToStartOfCentralDirectory)

        guard cdOffset <= archiveSize else { throw Archive.ArchiveError.invalidCentralDirectoryOffset }
        guard cdSize <= UInt64(Int.max) else { throw Archive.ArchiveError.invalidCentralDirectorySize }

        let centralDirectoryData = try await RemoteArchive.readExactly(
            source: source,
            offset: cdOffset,
            length: Int(cdSize)
        )
        guard centralDirectoryData.count == Int(cdSize) else { throw Archive.ArchiveError.unreadableArchive }
        self.centralDirectoryEntries = try RemoteArchive.parseCentralDirectory(data: centralDirectoryData,
                                                                               expectedEntryCount: entryCount,
                                                                               pathEncoding: pathEncoding)
    }

    public func centralDirectoryEntry(forPath path: String) -> CentralDirectoryEntry? {
        self.centralDirectoryEntries.first { $0.path == path }
    }

    public func extract(_ entry: CentralDirectoryEntry,
                        bufferSize: Int = defaultReadChunkSize,
                        skipCRC32: Bool = false,
                        consumer: @Sendable (Data) async throws -> Void) async throws {
        guard bufferSize > 0 else { throw Archive.ArchiveError.invalidBufferSize }

        let cds = entry.centralDirectoryStructure
        guard !cds.isEncrypted else { throw Archive.ArchiveError.unreadableArchive }

        if entry.type == .directory {
            try await consumer(Data())
            return
        }

        let localHeaderOffset = entry.localHeaderOffset
        guard localHeaderOffset <= source.size else { throw Archive.ArchiveError.invalidLocalHeaderDataOffset }
        // Remote extraction should not rely on cancellation of a "stream-to-EOF" request.
        // Instead, read the fixed Local File Header fields (30 bytes) to compute the entry's data offset, then
        // stream exactly `compressedSize` bytes starting at that offset. This matches the intended request pattern:
        // 1) tiny read for local header, 2) streamed request for entry payload.
        let fixedHeader = try await RemoteArchive.readExactly(
            source: source,
            offset: localHeaderOffset,
            length: Entry.LocalFileHeader.size
        )
        guard fixedHeader.count == Entry.LocalFileHeader.size else { throw Archive.ArchiveError.unreadableArchive }
        let localSignature: UInt32 = fixedHeader.scanValue(start: 0)
        guard localSignature == UInt32(localFileHeaderStructSignature) else { throw Archive.ArchiveError.unreadableArchive }

        let fileNameLength: UInt16 = fixedHeader.scanValue(start: 26)
        let extraFieldLength: UInt16 = fixedHeader.scanValue(start: 28)

        let (offsetAfterFixedHeader, fixedHeaderOverflow) = localHeaderOffset.addingReportingOverflow(
            UInt64(Entry.LocalFileHeader.size)
        )
        let (offsetAfterFileName, fileNameOverflow) = offsetAfterFixedHeader.addingReportingOverflow(
            UInt64(fileNameLength)
        )
        let (dataOffset, extraFieldOverflow) = offsetAfterFileName.addingReportingOverflow(
            UInt64(extraFieldLength)
        )
        guard !fixedHeaderOverflow,
              !fileNameOverflow,
              !extraFieldOverflow,
              dataOffset <= source.size else {
            throw Archive.ArchiveError.invalidLocalHeaderDataOffset
        }

        let compressedSize = entry.compressedSize
        guard compressedSize <= UInt64(Int.max) else { throw Archive.ArchiveError.invalidEntrySize }
        let compressedLength = Int(compressedSize)
        let compressedStream = try await source.stream(offset: dataOffset,
                                                       length: compressedLength,
                                                       chunkSize: bufferSize)

        if cds.compressionMethod == CompressionMethod.none.rawValue {
            var bytesWritten: UInt64 = 0
            var crc32 = CRC32(0)
            for try await chunk in compressedStream {
                bytesWritten += UInt64(chunk.count)
                if !skipCRC32 { crc32 = chunk.crc32(checksum: crc32) }
                try await consumer(chunk)
            }
            if !skipCRC32, crc32 != cds.crc32 { throw Archive.ArchiveError.invalidCRC32 }
            if bytesWritten != entry.uncompressedSize { throw Archive.ArchiveError.invalidEntrySize }
            return
        }

        guard cds.compressionMethod == CompressionMethod.deflate.rawValue else {
            throw Archive.ArchiveError.invalidCompressionMethod
        }

        final actor BytesWritten {
            private(set) var value: UInt64 = 0
            func add(_ bytes: Int) { value += UInt64(bytes) }
        }
        let bytesWritten = BytesWritten()
        let crc32 = try await Data.decompress(bufferSize: bufferSize,
                                              skipCRC32: skipCRC32,
                                              stream: compressedStream) { data in
            await bytesWritten.add(data.count)
            try await consumer(data)
        }
        let totalBytesWritten = await bytesWritten.value
        if !skipCRC32, crc32 != cds.crc32 { throw Archive.ArchiveError.invalidCRC32 }
        if totalBytesWritten != entry.uncompressedSize { throw Archive.ArchiveError.invalidEntrySize }
    }

    /// Returns an `AsyncThrowingStream` of decompressed entry bytes.
    ///
    /// - Note: This is a convenience API. The `consumer:` variant provides stronger backpressure because it awaits
    ///   consumption before continuing decompression.
    public func extractStream(_ entry: CentralDirectoryEntry,
                              bufferSize: Int = defaultReadChunkSize,
                              skipCRC32: Bool = false) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream(Data.self, bufferingPolicy: .bufferingOldest(1)) { continuation in
            let task = Task {
                do {
                    try await self.extract(entry, bufferSize: bufferSize, skipCRC32: skipCRC32) { chunk in
                        // `chunk` can be backed by a reused scratch buffer (e.g. `Data(bytesNoCopy: ...)`).
                        // Ensure we copy so yielded values remain stable after this closure returns.
                        let stableChunk = Data(chunk)
                        while true {
                            try Task.checkCancellation()
                            switch continuation.yield(stableChunk) {
                            case .enqueued:
                                return
                            case .dropped:
                                // `bufferingOldest(1)` drops the offered chunk while the previous chunk is pending.
                                // Retry cooperatively so a slow consumer applies backpressure instead of losing data.
                                await Task<Never, Never>.yield()
                            case .terminated:
                                throw CancellationError()
                            @unknown default:
                                throw CancellationError()
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private extension RemoteArchive {
    static func readExactly(source: any AsyncArchiveByteSource,
                            offset: UInt64,
                            length: Int) async throws -> Data {
        guard length >= 0 else { throw Archive.ArchiveError.unreadableArchive }

        var result = Data()
        while result.count < length {
            let remainingLength = length - result.count
            let (readOffset, overflow) = offset.addingReportingOverflow(UInt64(result.count))
            guard !overflow else { throw Archive.ArchiveError.unreadableArchive }

            let chunk = try await source.read(offset: readOffset, length: remainingLength)
            guard !chunk.isEmpty else { break }
            guard chunk.count <= remainingLength else { throw Archive.ArchiveError.unreadableArchive }
            result.append(chunk)
        }
        return result
    }

    static func parseCentralDirectory(data: Data,
                                      expectedEntryCount: UInt64,
                                      pathEncoding: String.Encoding?) throws -> [CentralDirectoryEntry] {
        var entries: [CentralDirectoryEntry] = []
        entries.reserveCapacity(Swift.min(Int(expectedEntryCount), 4096))
        var index: UInt64 = 0
        var cursor = 0
        while index < expectedEntryCount {
            guard cursor + Entry.CentralDirectoryStructure.size <= data.count else {
                throw Archive.ArchiveError.unreadableArchive
            }
            let fixed = data.subdata(in: cursor..<cursor + Entry.CentralDirectoryStructure.size)
            guard let cds = Entry.CentralDirectoryStructure(data: fixed, additionalDataProvider: { additionalSize in
                let start = cursor + Entry.CentralDirectoryStructure.size
                let end = start + additionalSize
                guard end <= data.count else { throw Archive.ArchiveError.unreadableArchive }
                return data.subdata(in: start..<end)
            }) else {
                throw Archive.ArchiveError.unreadableArchive
            }
            entries.append(Archive.CentralDirectoryEntry(centralDirectoryStructure: cds, pathEncoding: pathEncoding))
            cursor += Entry.CentralDirectoryStructure.size
            cursor += Int(cds.fileNameLength) + Int(cds.extraFieldLength) + Int(cds.fileCommentLength)
            index += 1
        }
        return entries
    }

    static func scanForZIP64EndOfCentralDirectory(source: any AsyncArchiveByteSource,
                                                  fileSize: UInt64,
                                                  eocdOffset: UInt64,
                                                  tailData: Data,
                                                  tailOffset: UInt64) async throws -> Archive.ZIP64EndOfCentralDirectory? {
        guard UInt64(Archive.ZIP64EndOfCentralDirectoryLocator.size) < eocdOffset else { return nil }

        let locatorOffset = eocdOffset - UInt64(Archive.ZIP64EndOfCentralDirectoryLocator.size)
        let locatorData: Data = {
            let localStart = Int64(locatorOffset) - Int64(tailOffset)
            if localStart >= 0, localStart + Int64(Archive.ZIP64EndOfCentralDirectoryLocator.size) <= Int64(tailData.count) {
                let start = Int(localStart)
                return tailData.subdata(in: start..<start + Archive.ZIP64EndOfCentralDirectoryLocator.size)
            }
            return Data()
        }()

        let resolvedLocatorData: Data
        if locatorData.count == Archive.ZIP64EndOfCentralDirectoryLocator.size {
            resolvedLocatorData = locatorData
        } else {
            resolvedLocatorData = try await RemoteArchive.readExactly(
                source: source,
                offset: locatorOffset,
                length: Archive.ZIP64EndOfCentralDirectoryLocator.size
            )
        }
        guard let locator = Archive.ZIP64EndOfCentralDirectoryLocator(
            data: resolvedLocatorData,
            additionalDataProvider: { _ in Data() }
        ) else { return nil }

        let recordOffset = locator.relativeOffsetOfZIP64EOCDRecord
        let (recordEndOffset, overflow) = recordOffset.addingReportingOverflow(
            UInt64(Archive.ZIP64EndOfCentralDirectoryRecord.size)
        )
        guard recordOffset <= fileSize, !overflow, recordEndOffset <= fileSize else { return nil }

        let recordData: Data = {
            let localStart = Int64(recordOffset) - Int64(tailOffset)
            if localStart >= 0, localStart + Int64(Archive.ZIP64EndOfCentralDirectoryRecord.size) <= Int64(tailData.count) {
                let start = Int(localStart)
                return tailData.subdata(in: start..<start + Archive.ZIP64EndOfCentralDirectoryRecord.size)
            }
            return Data()
        }()

        let resolvedRecordData: Data
        if recordData.count == Archive.ZIP64EndOfCentralDirectoryRecord.size {
            resolvedRecordData = recordData
        } else {
            resolvedRecordData = try await RemoteArchive.readExactly(
                source: source,
                offset: recordOffset,
                length: Archive.ZIP64EndOfCentralDirectoryRecord.size
            )
        }
        guard let record = Archive.ZIP64EndOfCentralDirectoryRecord(
            data: resolvedRecordData,
            additionalDataProvider: { _ in Data() }
        ) else { return nil }

        return Archive.ZIP64EndOfCentralDirectory(record: record, locator: locator)
    }
}

#endif
