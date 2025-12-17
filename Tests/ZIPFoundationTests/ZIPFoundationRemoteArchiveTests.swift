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
    private var reads: [(offset: UInt64, length: Int)] = []
    private var streams: [(offset: UInt64, length: Int, chunkSize: Int)] = []

    init(data: Data) {
        self.data = data
        self.size = UInt64(data.count)
    }

    func snapshot() -> (reads: [(offset: UInt64, length: Int)],
                        streams: [(offset: UInt64, length: Int, chunkSize: Int)]) {
        (reads: reads, streams: streams)
    }

    func read(offset: UInt64, length: Int) async throws -> Data {
        reads.append((offset: offset, length: length))
        guard offset <= size else { return Data() }
        let start = Int(offset)
        let end = Swift.min(start + Swift.max(0, length), data.count)
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

                // Extraction should use a single streamed request starting at the local header offset (no extra reads).
                let snapshotAfterExtract = await source.snapshot()
                XCTAssertEqual(snapshotAfterExtract.reads.count, readsAfterOpen)
                XCTAssertEqual(snapshotAfterExtract.streams.count, streamsAfterOpen + 1)
                XCTAssertTrue(snapshotAfterExtract.streams.dropFirst(streamsAfterOpen).contains {
                    $0.offset == cdEntry.localHeaderOffset
                    && $0.length == Int(source.size - cdEntry.localHeaderOffset)
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
}

#endif
