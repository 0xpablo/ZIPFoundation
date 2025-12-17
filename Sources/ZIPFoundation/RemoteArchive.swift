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
        let tailData = try await source.read(offset: tailOffset, length: tailLength)

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

        let centralDirectoryData = try await source.read(offset: cdOffset, length: Int(cdSize))
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
        let cds = entry.centralDirectoryStructure
        guard !cds.isEncrypted else { throw Archive.ArchiveError.unreadableArchive }

        if entry.type == .directory {
            try await consumer(Data())
            return
        }

        let localHeaderOffset = entry.localHeaderOffset
        guard localHeaderOffset <= source.size else { throw Archive.ArchiveError.invalidLocalHeaderDataOffset }

        // Single-request extraction:
        // Start streaming at the Local File Header offset, parse header fields from the stream, then consume exactly
        // the entry's compressed bytes. The underlying networking layer should cancel the request when the stream is
        // terminated early.
        let remainingBytes = source.size - localHeaderOffset
        guard remainingBytes <= UInt64(Int.max) else { throw Archive.ArchiveError.invalidEntrySize }
        var iterator = try await source.stream(offset: localHeaderOffset,
                                               length: Int(remainingBytes),
                                               chunkSize: bufferSize).makeAsyncIterator()
        var buffer = Data()

        func fillBufferIfNeeded() async throws {
            if buffer.isEmpty {
                guard let next = try await iterator.next() else { throw Archive.ArchiveError.unreadableArchive }
                buffer.append(next)
            }
        }

        func readExactly(_ count: Int) async throws -> Data {
            var result = Data()
            result.reserveCapacity(count)
            var remaining = count
            while remaining > 0 {
                try await fillBufferIfNeeded()
                let take = Swift.min(remaining, buffer.count)
                result.append(buffer.prefix(take))
                buffer.removeFirst(take)
                remaining -= take
            }
            return result
        }

        func discardExactly(_ count: Int) async throws {
            var remaining = count
            while remaining > 0 {
                try await fillBufferIfNeeded()
                let take = Swift.min(remaining, buffer.count)
                buffer.removeFirst(take)
                remaining -= take
            }
        }

        let fixedHeader = try await readExactly(Entry.LocalFileHeader.size)
        let localSignature: UInt32 = fixedHeader.scanValue(start: 0)
        guard localSignature == UInt32(localFileHeaderStructSignature) else { throw Archive.ArchiveError.unreadableArchive }

        let fileNameLength: UInt16 = fixedHeader.scanValue(start: 26)
        let extraFieldLength: UInt16 = fixedHeader.scanValue(start: 28)
        let variableHeaderSize = Int(fileNameLength) + Int(extraFieldLength)
        try await discardExactly(variableHeaderSize)

        let compressedSize = entry.compressedSize
        guard compressedSize <= UInt64(Int.max) else { throw Archive.ArchiveError.invalidEntrySize }
        let compressedLength = Int(compressedSize)

        struct SliceSequence: AsyncSequence {
            typealias Element = Data
            struct AsyncIterator: AsyncIteratorProtocol {
                var upstream: AsyncThrowingStream<Data, Error>.AsyncIterator
                var buffer: Data
                var remaining: Int
                let chunkSize: Int

                mutating func next() async throws -> Data? {
                    guard remaining > 0 else { return nil }
                    if buffer.isEmpty {
                        guard let next = try await upstream.next() else { throw Archive.ArchiveError.unreadableArchive }
                        buffer.append(next)
                    }
                    let take = Swift.min(remaining, Swift.min(chunkSize, buffer.count))
                    let chunk = Data(buffer.prefix(take))
                    buffer.removeFirst(take)
                    remaining -= take
                    return chunk
                }
            }

            let upstream: AsyncThrowingStream<Data, Error>.AsyncIterator
            let buffer: Data
            let remaining: Int
            let chunkSize: Int

            func makeAsyncIterator() -> AsyncIterator {
                AsyncIterator(upstream: upstream, buffer: buffer, remaining: remaining, chunkSize: chunkSize)
            }
        }

        if cds.compressionMethod == CompressionMethod.none.rawValue {
            var bytesWritten: UInt64 = 0
            var crc32 = CRC32(0)
            var dataIterator = SliceSequence(upstream: iterator, buffer: buffer, remaining: compressedLength, chunkSize: bufferSize)
                .makeAsyncIterator()
            while let chunk = try await dataIterator.next() {
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
        let compressedStream = SliceSequence(upstream: iterator,
                                             buffer: buffer,
                                             remaining: compressedLength,
                                             chunkSize: bufferSize)
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
                        try Task.checkCancellation()
                        continuation.yield(chunk)
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
            resolvedLocatorData = try await source.read(offset: locatorOffset,
                                                       length: Archive.ZIP64EndOfCentralDirectoryLocator.size)
        }
        guard let locator = Archive.ZIP64EndOfCentralDirectoryLocator(
            data: resolvedLocatorData,
            additionalDataProvider: { _ in Data() }
        ) else { return nil }

        let recordOffset = locator.relativeOffsetOfZIP64EOCDRecord
        guard recordOffset <= fileSize,
              recordOffset + UInt64(Archive.ZIP64EndOfCentralDirectoryRecord.size) <= fileSize else { return nil }

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
            resolvedRecordData = try await source.read(offset: recordOffset,
                                                      length: Archive.ZIP64EndOfCentralDirectoryRecord.size)
        }
        guard let record = Archive.ZIP64EndOfCentralDirectoryRecord(
            data: resolvedRecordData,
            additionalDataProvider: { _ in Data() }
        ) else { return nil }

        return Archive.ZIP64EndOfCentralDirectory(record: record, locator: locator)
    }
}

#endif
