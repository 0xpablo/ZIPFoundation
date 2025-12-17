//
//  ZIPFoundationByteSourceTests.swift
//  ZIPFoundation
//
//  Copyright © 2017-2025 Thomas Zoechling, https://www.peakstep.com and the ZIP Foundation project authors.
//  Released under the MIT License.
//
//  See https://github.com/weichsel/ZIPFoundation/blob/master/LICENSE for license information.
//

import Foundation
import XCTest
@testable import ZIPFoundation

final class RecordingByteSource: ArchiveByteSource {
    private let data: Data
    private(set) var reads: [(offset: UInt64, length: Int)] = []

    init(data: Data) {
        self.data = data
    }

    var size: UInt64 { UInt64(self.data.count) }

    func read(offset: UInt64, length: Int) throws -> Data {
        self.reads.append((offset: offset, length: length))
        guard offset <= self.size else { return Data() }
        let start = Int(offset)
        let end = min(start + max(0, length), self.data.count)
        guard start <= end else { return Data() }
        return self.data.subdata(in: start..<end)
    }
}

extension ZIPFoundationTests {

    func testByteSourceArchiveInitReadsOnlyTailWindow() throws {
        var archiveURL = ZIPFoundationTests.resourceDirectoryURL
        archiveURL.appendPathComponent("testExtractUncompressedFolderEntries")
        archiveURL.appendPathExtension("zip")
        let archiveData = try Data(contentsOf: archiveURL)

        let source = RecordingByteSource(data: archiveData)
        _ = try Archive(byteSource: source)

        XCTAssertFalse(source.reads.isEmpty)
        let tailWindow = UInt64(min(maxDirectoryEndOffset, Int64(archiveData.count)))
        let minExpectedOffset = archiveData.count > Int(tailWindow) ? UInt64(archiveData.count) - tailWindow : 0
        for read in source.reads {
            XCTAssertGreaterThanOrEqual(read.offset, minExpectedOffset)
        }
    }

    func testExtractEntriesFromByteSourceArchive() throws {
        var archiveURL = ZIPFoundationTests.resourceDirectoryURL
        archiveURL.appendPathComponent("testExtractCompressedFolderEntries")
        archiveURL.appendPathExtension("zip")
        let archiveData = try Data(contentsOf: archiveURL)

        let source = RecordingByteSource(data: archiveData)
        let archive = try Archive(byteSource: source)
        XCTAssertTrue(archive.checkIntegrity())
    }

    func testEOCDScanIgnoresSignatureInEntryData() throws {
        var destinationArchiveURL = ZIPFoundationTests.tempZipDirectoryURL
        destinationArchiveURL.appendPathComponent(ProcessInfo.processInfo.globallyUniqueString)
        destinationArchiveURL.appendPathExtension("zip")

        let payload = Data([0x50, 0x4b, 0x05, 0x06] + Array(repeating: 0x11, count: 4096))
        let archive = try Archive(url: destinationArchiveURL, accessMode: .create)
        try archive.addEntry(with: "sig.bin",
                             type: .file,
                             uncompressedSize: Int64(payload.count),
                             bufferSize: 128,
                             provider: { position, size -> Data in
            let start = Int(position)
            let end = min(start + size, payload.count)
            return payload.subdata(in: start..<end)
        })

        let archiveData = try Data(contentsOf: destinationArchiveURL)
        let source = RecordingByteSource(data: archiveData)
        let byteSourceArchive = try Archive(byteSource: source)
        XCTAssertTrue(byteSourceArchive.checkIntegrity())
    }

    func testCentralDirectoryEntriesFromByteSourceAvoidLocalHeaderReads() throws {
        var archiveURL = ZIPFoundationTests.resourceDirectoryURL
        archiveURL.appendPathComponent("testUnzipItem")
        archiveURL.appendPathExtension("zip")
        let archiveData = try Data(contentsOf: archiveURL)

        let source = RecordingByteSource(data: archiveData)
        let archive = try Archive(byteSource: source)
        let readsAfterInit = source.reads.count

        _ = try archive.centralDirectoryEntries()
        let cdOffset = archive.offsetToStartOfCentralDirectory
        for read in source.reads.dropFirst(readsAfterInit) {
            XCTAssertGreaterThanOrEqual(read.offset, cdOffset)
        }
    }

    func testCentralDirectoryLookupFromByteSourceAvoidLocalHeaderReads() throws {
        var archiveURL = ZIPFoundationTests.resourceDirectoryURL
        archiveURL.appendPathComponent("testUnzipItem")
        archiveURL.appendPathExtension("zip")
        let archiveData = try Data(contentsOf: archiveURL)

        let source = RecordingByteSource(data: archiveData)
        let archive = try Archive(byteSource: source)
        let readsAfterInit = source.reads.count

        let cdEntry = try archive.centralDirectoryEntry(forPath: "data.random")
        XCTAssertNotNil(cdEntry)

        let cdOffset = archive.offsetToStartOfCentralDirectory
        for read in source.reads.dropFirst(readsAfterInit) {
            XCTAssertGreaterThanOrEqual(read.offset, cdOffset)
        }
    }

    func testMaterializeEntryFromCentralDirectoryEntryReadsLocalHeader() throws {
        var archiveURL = ZIPFoundationTests.resourceDirectoryURL
        archiveURL.appendPathComponent("testUnzipItem")
        archiveURL.appendPathExtension("zip")
        let archiveData = try Data(contentsOf: archiveURL)

        let source = RecordingByteSource(data: archiveData)
        let archive = try Archive(byteSource: source)
        let readsAfterInit = source.reads.count

        let cdEntry = try XCTUnwrap(archive.centralDirectoryEntry(forPath: "data.random"))
        let readsAfterLookup = source.reads.count
        _ = try archive.entry(fromCentralDirectoryEntry: cdEntry)

        XCTAssertTrue(source.reads.count > readsAfterLookup)
        XCTAssertTrue(source.reads.dropFirst(readsAfterLookup).contains { $0.offset == cdEntry.localHeaderOffset })
        // Ensure we did not read all local headers just to materialize one entry.
        XCTAssertTrue(source.reads.dropFirst(readsAfterInit).contains { $0.offset < archive.offsetToStartOfCentralDirectory })
    }
}
