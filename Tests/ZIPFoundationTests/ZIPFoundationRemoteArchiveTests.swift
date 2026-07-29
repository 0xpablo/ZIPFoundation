//
//  ZIPFoundationRemoteArchiveTests.swift
//  ZIPFoundation
//
//  Copyright © 2017-2025 Thomas Zoechling, https://www.peakstep.com and the ZIP Foundation project authors.
//  Released under the MIT License.
//
//  See https://github.com/weichsel/ZIPFoundation/blob/master/LICENSE for license information.
//

#if swift(>=5.5)

import Foundation
import XCTest
@testable import ZIPFoundation

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
private actor RecordingAsyncByteSource: AsyncArchiveByteSource {
    nonisolated let size: UInt64
    private let data: Data
    private let maxReadLength: Int?
    private var reads: [(offset: UInt64, length: Int)] = []
    private var streams: [(offset: UInt64, length: Int, chunkSize: Int)] = []

    init(data: Data, maxReadLength: Int? = nil) {
        self.data = data
        self.size = UInt64(data.count)
        self.maxReadLength = maxReadLength
    }

    func snapshot() -> (reads: [(offset: UInt64, length: Int)],
                        streams: [(offset: UInt64, length: Int, chunkSize: Int)]) {
        (reads: reads, streams: streams)
    }

    func read(offset: UInt64, length: Int) async throws -> Data {
        reads.append((offset: offset, length: length))
        guard offset <= size else { return Data() }
        let start = Int(offset)
        let limitedLength = Swift.min(Swift.max(0, length), maxReadLength ?? Int.max)
        let end = Swift.min(start + limitedLength, data.count)
        guard start <= end else { return Data() }
        return data.subdata(in: start..<end)
    }

    func stream(offset: UInt64, length: Int, chunkSize: Int) async throws -> AsyncThrowingStream<Data, Error> {
        streams.append((offset: offset, length: length, chunkSize: chunkSize))

        let start = Int(offset)
        let end = Swift.min(start + Swift.max(0, length), data.count)
        let slice = (start < end) ? data.subdata(in: start..<end) : Data()

        return AsyncThrowingStream { continuation in
            var cursor = 0
            while cursor < slice.count {
                let nextEnd = Swift.min(cursor + Swift.max(1, chunkSize), slice.count)
                continuation.yield(slice.subdata(in: cursor..<nextEnd))
                cursor = nextEnd
            }
            continuation.finish()
        }
    }
}

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
extension ZIPFoundationTests {

    func testRemoteArchiveOpenReadsTailAndCentralDirectory() throws {
        let expectation = self.expectation(description: "open remote archive")
        defer { self.wait(for: [expectation], timeout: 10.0) }

        Task {
            defer { expectation.fulfill() }
            do {
                var archiveURL = ZIPFoundationTests.resourceDirectoryURL
                archiveURL.appendPathComponent("testExtractCompressedFolderEntries")
                archiveURL.appendPathExtension("zip")
                let archiveData = try Data(contentsOf: archiveURL)

                let source = RecordingAsyncByteSource(data: archiveData)
                let remote = try await RemoteArchive(source: source)

                let snapshot = await source.snapshot()
                XCTAssertGreaterThanOrEqual(snapshot.reads.count, 2)

                let expectedTailLength = Int(Swift.min(UInt64(maxDirectoryEndOffset), UInt64(archiveData.count)))
                let expectedTailOffset = UInt64(archiveData.count) - UInt64(expectedTailLength)
                XCTAssertTrue(snapshot.reads.contains { $0.offset == expectedTailOffset && $0.length == expectedTailLength })
                XCTAssertTrue(snapshot.reads.contains {
                    $0.offset == remote.offsetToStartOfCentralDirectory && $0.length == Int(remote.sizeOfCentralDirectory)
                })
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRemoteArchiveExtractMatchesSynchronousArchive() throws {
        let expectation = self.expectation(description: "extract remote archive entry")
        defer { self.wait(for: [expectation], timeout: 20.0) }

        Task {
            defer { expectation.fulfill() }
            do {
                var archiveURL = ZIPFoundationTests.resourceDirectoryURL
                archiveURL.appendPathComponent("testExtractCompressedFolderEntries")
                archiveURL.appendPathExtension("zip")
                let archiveData = try Data(contentsOf: archiveURL)

                // Expected output from synchronous in-memory archive.
                let syncArchive = try Archive(data: archiveData, accessMode: .read)
                guard let syncEntry = syncArchive["test/faust.txt"] else {
                    XCTFail("Missing test entry")
                    return
                }
                var expected = Data()
                _ = try syncArchive.extract(syncEntry, bufferSize: 32 * 1024) { expected.append($0) }

                let source = RecordingAsyncByteSource(data: archiveData)
                let remote = try await RemoteArchive(source: source)
                guard let cdEntry = remote.centralDirectoryEntry(forPath: "test/faust.txt") else {
                    XCTFail("Missing central directory entry")
                    return
                }

                let snapshotAfterOpen = await source.snapshot()
                let readsAfterOpen = snapshotAfterOpen.reads.count
                let streamsAfterOpen = snapshotAfterOpen.streams.count
                final actor Collector {
                    private(set) var data = Data()
                    func append(_ chunk: Data) { data.append(chunk) }
                }
                let collector = Collector()
                try await remote.extract(cdEntry, bufferSize: 32 * 1024) { chunk in
                    await collector.append(chunk)
                }
                let actual = await collector.data

                XCTAssertEqual(actual, expected)

                // Extraction should perform one small read for the local header fixed fields, and one streamed request
                // for the entry's compressed payload.
                let snapshotAfterExtract = await source.snapshot()
                XCTAssertEqual(snapshotAfterExtract.reads.count, readsAfterOpen + 1)
                XCTAssertEqual(snapshotAfterExtract.streams.count, streamsAfterOpen + 1)

                let localHeaderOffset = cdEntry.localHeaderOffset
                let fixedHeader = archiveData.subdata(in: Int(localHeaderOffset)..<Int(localHeaderOffset) + Entry.LocalFileHeader.size)
                let fileNameLength: UInt16 = fixedHeader.scanValue(start: 26)
                let extraFieldLength: UInt16 = fixedHeader.scanValue(start: 28)
                let dataOffset = localHeaderOffset
                    + UInt64(Entry.LocalFileHeader.size)
                    + UInt64(fileNameLength)
                    + UInt64(extraFieldLength)
                let compressedLength = Int(cdEntry.compressedSize)

                XCTAssertTrue(snapshotAfterExtract.reads.contains { $0.offset == localHeaderOffset && $0.length == Entry.LocalFileHeader.size })
                XCTAssertTrue(snapshotAfterExtract.streams.dropFirst(streamsAfterOpen).contains {
                    $0.offset == dataOffset
                    && $0.length == compressedLength
                })
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRemoteArchiveExtractStreamMatchesConsumerExtract() throws {
        let expectation = self.expectation(description: "extract remote archive stream")
        defer { self.wait(for: [expectation], timeout: 20.0) }

        Task {
            defer { expectation.fulfill() }
            do {
                var archiveURL = ZIPFoundationTests.resourceDirectoryURL
                archiveURL.appendPathComponent("testExtractCompressedFolderEntries")
                archiveURL.appendPathExtension("zip")
                let archiveData = try Data(contentsOf: archiveURL)

                let source = RecordingAsyncByteSource(data: archiveData)
                let remote = try await RemoteArchive(source: source)
                guard let cdEntry = remote.centralDirectoryEntry(forPath: "test/faust.txt") else {
                    XCTFail("Missing central directory entry")
                    return
                }

                final actor Collector {
                    private(set) var data = Data()
                    func append(_ chunk: Data) { data.append(chunk) }
                    func snapshot() -> Data { data }
                }
                let fromStream = Collector()
                let fromConsumer = Collector()

                for try await chunk in remote.extractStream(cdEntry, bufferSize: 32 * 1024) {
                    await fromStream.append(chunk)
                }
                try await remote.extract(cdEntry, bufferSize: 32 * 1024) { chunk in
                    await fromConsumer.append(chunk)
                }

                let streamData = await fromStream.snapshot()
                let consumerData = await fromConsumer.snapshot()
                XCTAssertEqual(streamData, consumerData)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRemoteArchiveExtractStreamPreservesChunksForSlowConsumer() throws {
        let expectation = self.expectation(description: "extract remote archive stream with slow consumer")
        defer { self.wait(for: [expectation], timeout: 20.0) }

        Task {
            defer { expectation.fulfill() }
            do {
                var archiveURL = ZIPFoundationTests.resourceDirectoryURL
                archiveURL.appendPathComponent("testExtractCompressedFolderEntries")
                archiveURL.appendPathExtension("zip")
                let archiveData = try Data(contentsOf: archiveURL)

                let syncArchive = try Archive(data: archiveData, accessMode: .read)
                guard let syncEntry = syncArchive["test/faust.txt"] else {
                    XCTFail("Missing test entry")
                    return
                }
                var expected = Data()
                _ = try syncArchive.extract(syncEntry, bufferSize: 4 * 1024) { expected.append($0) }

                let source = RecordingAsyncByteSource(data: archiveData)
                let remote = try await RemoteArchive(source: source)
                guard let cdEntry = remote.centralDirectoryEntry(forPath: "test/faust.txt") else {
                    XCTFail("Missing central directory entry")
                    return
                }

                var actual = Data()
                for try await chunk in remote.extractStream(cdEntry, bufferSize: 4 * 1024) {
                    try await Task<Never, Never>.sleep(nanoseconds: 1_000_000)
                    actual.append(chunk)
                }
                XCTAssertEqual(actual, expected)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRemoteArchiveSupportsZIP64WithShortReads() throws {
        let expectation = self.expectation(description: "extract ZIP64 remote archive with short reads")
        defer { self.wait(for: [expectation], timeout: 20.0) }

        Task {
            defer { expectation.fulfill() }
            do {
                var archiveURL = ZIPFoundationTests.resourceDirectoryURL
                archiveURL.appendPathComponent("testExtractCompressedZIP64Entries")
                archiveURL.appendPathExtension("zip")
                let archiveData = try Data(contentsOf: archiveURL)

                let syncArchive = try Archive(data: archiveData, accessMode: .read)
                guard let syncEntry = syncArchive["testExtractCompressedZIP64Entries.png"] else {
                    XCTFail("Missing test entry")
                    return
                }
                var expected = Data()
                _ = try syncArchive.extract(syncEntry, bufferSize: 64) { expected.append($0) }

                let source = RecordingAsyncByteSource(data: archiveData, maxReadLength: 7)
                let remote = try await RemoteArchive(source: source)
                XCTAssertEqual(remote.totalNumberOfEntriesInCentralDirectory, 1)
                guard let cdEntry = remote.centralDirectoryEntry(
                    forPath: "testExtractCompressedZIP64Entries.png"
                ) else {
                    XCTFail("Missing central directory entry")
                    return
                }

                final actor Collector {
                    private(set) var data = Data()
                    func append(_ chunk: Data) { data.append(chunk) }
                }
                let collector = Collector()
                try await remote.extract(cdEntry, bufferSize: 64) { chunk in
                    await collector.append(chunk)
                }
                let actual = await collector.data
                XCTAssertEqual(actual, expected)

                let snapshot = await source.snapshot()
                XCTAssertGreaterThan(snapshot.reads.count, 4)
                XCTAssertTrue(snapshot.reads.contains { $0.length > 7 })
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRemoteArchiveExtractionPropagatesCancellation() throws {
        let expectation = self.expectation(description: "cancel remote archive extraction")
        defer { self.wait(for: [expectation], timeout: 20.0) }

        Task {
            defer { expectation.fulfill() }
            do {
                var archiveURL = ZIPFoundationTests.resourceDirectoryURL
                archiveURL.appendPathComponent("testExtractCompressedFolderEntries")
                archiveURL.appendPathExtension("zip")
                let archiveData = try Data(contentsOf: archiveURL)

                let source = RecordingAsyncByteSource(data: archiveData)
                let remote = try await RemoteArchive(source: source)
                guard let cdEntry = remote.centralDirectoryEntry(forPath: "test/faust.txt") else {
                    XCTFail("Missing central directory entry")
                    return
                }

                do {
                    try await remote.extract(cdEntry, bufferSize: 4 * 1024) { _ in
                        throw CancellationError()
                    }
                    XCTFail("Expected extraction to be cancelled")
                } catch is CancellationError {
                    // Expected.
                }
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRemoteArchiveRejectsMalformedZIP64RecordOffset() throws {
        let expectation = self.expectation(description: "reject malformed ZIP64 record offset")
        defer { self.wait(for: [expectation], timeout: 20.0) }

        Task {
            defer { expectation.fulfill() }
            do {
                var archiveURL = ZIPFoundationTests.resourceDirectoryURL
                archiveURL.appendPathComponent("testExtractCompressedZIP64Entries")
                archiveURL.appendPathExtension("zip")
                var archiveData = try Data(contentsOf: archiveURL)

                let locatorOffset = archiveData.count
                    - Archive.EndOfCentralDirectoryRecord.size
                    - Archive.ZIP64EndOfCentralDirectoryLocator.size
                XCTAssertEqual(
                    archiveData.scanValue(start: locatorOffset),
                    UInt32(zip64EOCDLocatorStructSignature)
                )

                var invalidRecordOffset = UInt64.max.littleEndian
                withUnsafeBytes(of: &invalidRecordOffset) { bytes in
                    let offsetField = locatorOffset + 8
                    archiveData.replaceSubrange(offsetField..<offsetField + bytes.count, with: bytes)
                }

                do {
                    _ = try await RemoteArchive(source: RecordingAsyncByteSource(data: archiveData))
                    XCTFail("Expected malformed ZIP64 metadata to be rejected")
                } catch {
                    // Any archive parsing error is acceptable; the malformed offset must not overflow or trap.
                }
            } catch {
                XCTFail("Unexpected error while preparing test: \(error)")
            }
        }
    }
}

#endif
