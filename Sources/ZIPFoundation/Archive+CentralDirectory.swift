//
//  Archive+CentralDirectory.swift
//  ZIPFoundation
//
//  Copyright © 2017-2025 Thomas Zoechling, https://www.peakstep.com and the ZIP Foundation project authors.
//  Released under the MIT License.
//
//  See https://github.com/weichsel/ZIPFoundation/blob/master/LICENSE for license information.
//

import Foundation

extension Archive {
    /// Metadata for a ZIP entry parsed from the Central Directory only.
    ///
    /// Unlike `Entry`, this type does not require reading the Local File Header.
    /// It is intended for efficiently listing or looking up entries in remote/range-backed archives.
    public struct CentralDirectoryEntry: Equatable {
        public let path: String

        internal let centralDirectoryStructure: Entry.CentralDirectoryStructure

        internal init(
            centralDirectoryStructure: Entry.CentralDirectoryStructure,
            pathEncoding: String.Encoding?
        ) {
            self.centralDirectoryStructure = centralDirectoryStructure
            let encoding = pathEncoding
            ?? (centralDirectoryStructure.usesUTF8PathEncoding ? String.Encoding.utf8 : .codepage437)
            self.path = String(pathData: centralDirectoryStructure.fileNameData, encoding: encoding)
        }

        public static func == (lhs: CentralDirectoryEntry, rhs: CentralDirectoryEntry) -> Bool {
            lhs.path == rhs.path && lhs.localHeaderOffset == rhs.localHeaderOffset
        }

        /// The `EntryType` as inferred from Central Directory metadata.
        public var type: Entry.EntryType {
            // OS Type is stored in the upper byte of versionMadeBy.
            let osTypeRaw = self.centralDirectoryStructure.versionMadeBy >> 8
            let osType = Entry.OSType(rawValue: UInt(osTypeRaw)) ?? .unused
            var isDirectory = self.path.hasSuffix("/")
            switch osType {
            case .unix, .osx:
                // Use truncatingIfNeeded for safer conversion across platforms.
                let modeValue = UInt16(truncatingIfNeeded: self.centralDirectoryStructure.externalFileAttributes >> 16)
                let mode = mode_t(modeValue) & S_IFMT
                switch mode {
                case S_IFREG:
                    return .file
                case S_IFDIR:
                    return .directory
                case S_IFLNK:
                    return .symlink
                default:
                    return isDirectory ? .directory : .file
                }
            case .msdos:
                isDirectory = isDirectory || ((centralDirectoryStructure.externalFileAttributes >> 4) == 0x01)
                fallthrough
            default:
                return isDirectory ? .directory : .file
            }
        }

        /// Indicates whether or not the entry's contents are compressed.
        public var isCompressed: Bool {
            self.centralDirectoryStructure.compressionMethod != CompressionMethod.none.rawValue
        }

        /// Indicates whether or not the entry uses a data descriptor.
        public var usesDataDescriptor: Bool { self.centralDirectoryStructure.usesDataDescriptor }

        /// Indicates whether or not the entry is encrypted.
        public var isEncrypted: Bool { self.centralDirectoryStructure.isEncrypted }

        /// The entry's compressed size (from the Central Directory).
        public var compressedSize: UInt64 { self.centralDirectoryStructure.effectiveCompressedSize }

        /// The entry's uncompressed size (from the Central Directory).
        public var uncompressedSize: UInt64 { self.centralDirectoryStructure.effectiveUncompressedSize }

        /// The byte offset of the Local File Header in the archive.
        public var localHeaderOffset: UInt64 { self.centralDirectoryStructure.effectiveRelativeOffsetOfLocalHeader }
    }

    /// Returns all Central Directory entries without reading any Local File Headers.
    public func centralDirectoryEntries() throws -> [CentralDirectoryEntry] {
        var entries: [CentralDirectoryEntry] = []
        try self.forEachCentralDirectoryEntry { entries.append($0) }
        return entries
    }

    /// Iterates over Central Directory entries without reading any Local File Headers.
    public func forEachCentralDirectoryEntry(_ body: (CentralDirectoryEntry) throws -> Void) throws {
        let totalNumberOfEntriesInCD = self.totalNumberOfEntriesInCentralDirectory
        var directoryIndex = self.offsetToStartOfCentralDirectory
        var index: UInt64 = 0
        while index < totalNumberOfEntriesInCD {
            guard let centralDirStruct: CentralDirectoryStructure = Data.readStruct(from: self.archiveFile,
                                                                                    at: directoryIndex) else {
                throw ArchiveError.unreadableArchive
            }
            let entry = CentralDirectoryEntry(centralDirectoryStructure: centralDirStruct, pathEncoding: self.pathEncoding)
            try body(entry)
            directoryIndex += UInt64(CentralDirectoryStructure.size)
            directoryIndex += UInt64(centralDirStruct.fileNameLength)
            directoryIndex += UInt64(centralDirStruct.extraFieldLength)
            directoryIndex += UInt64(centralDirStruct.fileCommentLength)
            index += 1
        }
    }

    /// Looks up a Central Directory entry by path without reading all Local File Headers.
    ///
    /// - Note: The ZIP file format specification does not enforce unique paths for entries.
    ///   Therefore an archive can contain multiple entries with the same path. This method
    ///   always returns the first Central Directory entry with the given `path`.
    public func centralDirectoryEntry(forPath path: String) throws -> CentralDirectoryEntry? {
        let totalNumberOfEntriesInCD = self.totalNumberOfEntriesInCentralDirectory
        var directoryIndex = self.offsetToStartOfCentralDirectory
        var index: UInt64 = 0
        while index < totalNumberOfEntriesInCD {
            guard let centralDirStruct: CentralDirectoryStructure = Data.readStruct(from: self.archiveFile,
                                                                                    at: directoryIndex) else {
                throw ArchiveError.unreadableArchive
            }
            let entry = CentralDirectoryEntry(centralDirectoryStructure: centralDirStruct, pathEncoding: self.pathEncoding)
            if entry.path == path { return entry }
            directoryIndex += UInt64(CentralDirectoryStructure.size)
            directoryIndex += UInt64(centralDirStruct.fileNameLength)
            directoryIndex += UInt64(centralDirStruct.extraFieldLength)
            directoryIndex += UInt64(centralDirStruct.fileCommentLength)
            index += 1
        }
        return nil
    }

    /// Materializes an `Entry` from a Central Directory entry by reading its Local File Header.
    ///
    /// - Returns: An `Entry` or `nil` if the entry is unsupported (e.g. encrypted).
    public func entry(fromCentralDirectoryEntry entry: CentralDirectoryEntry) throws -> Entry? {
        let centralDirStruct = entry.centralDirectoryStructure
        let offset = centralDirStruct.effectiveRelativeOffsetOfLocalHeader
        guard offset <= UInt64(Int64.max) else {
            throw ArchiveError.invalidLocalHeaderDataOffset
        }
        guard let localFileHeader: Entry.LocalFileHeader = Data.readStruct(from: self.archiveFile, at: offset) else {
            throw ArchiveError.unreadableArchive
        }
        var dataDescriptor: Entry.DefaultDataDescriptor?
        var zip64DataDescriptor: Entry.ZIP64DataDescriptor?
        if centralDirStruct.usesDataDescriptor {
            let additionalSize = UInt64(localFileHeader.fileNameLength) + UInt64(localFileHeader.extraFieldLength)
            let isCompressed = centralDirStruct.compressionMethod != CompressionMethod.none.rawValue
            let dataSize = isCompressed ? centralDirStruct.effectiveCompressedSize : centralDirStruct.effectiveUncompressedSize
            let descriptorPosition = offset + UInt64(Entry.LocalFileHeader.size) + additionalSize + dataSize
            if centralDirStruct.isZIP64 {
                zip64DataDescriptor = Data.readStruct(from: self.archiveFile, at: descriptorPosition)
            } else {
                dataDescriptor = Data.readStruct(from: self.archiveFile, at: descriptorPosition)
            }
        }
        return Entry(centralDirectoryStructure: centralDirStruct, localFileHeader: localFileHeader,
                     dataDescriptor: dataDescriptor, zip64DataDescriptor: zip64DataDescriptor)
    }

    /// Looks up an `Entry` by path by scanning the Central Directory and reading only the matching Local File Header.
    ///
    /// This avoids reading all Local File Headers (unlike `subscript(path:)`), and is therefore better suited for
    /// range-backed archives.
    ///
    /// - Note: The ZIP file format specification does not enforce unique paths for entries.
    ///   Therefore an archive can contain multiple entries with the same path. This method
    ///   always returns the first `Entry` with the given `path`.
    public func entry(forPath path: String) throws -> Entry? {
        guard let cdEntry = try self.centralDirectoryEntry(forPath: path) else { return nil }
        return try self.entry(fromCentralDirectoryEntry: cdEntry)
    }
}
