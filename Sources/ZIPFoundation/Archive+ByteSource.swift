//
//  Archive+ByteSource.swift
//  ZIPFoundation
//
//  Copyright © 2017-2025 Thomas Zoechling, https://www.peakstep.com and the ZIP Foundation project authors.
//  Released under the MIT License.
//
//  See https://github.com/weichsel/ZIPFoundation/blob/master/LICENSE for license information.
//

import Foundation

/// A random-access byte source that can back a read-only ZIP `Archive`.
///
/// This enables range-based access to ZIP files (e.g. HTTP Content-Range), without requiring the full archive
/// to be present locally, as long as the data can be fetched by `offset` and `length`.
public protocol ArchiveByteSource {
    /// Total size of the archive in bytes.
    var size: UInt64 { get }

    /// Read up to `length` bytes from the archive starting at `offset`.
    ///
    /// - Parameters:
    ///   - offset: Byte offset from the start of the archive.
    ///   - length: Maximum number of bytes to read.
    /// - Returns: A `Data` buffer with `0...length` bytes. Returning fewer bytes indicates EOF.
    func read(offset: UInt64, length: Int) throws -> Data
}

extension Archive {
    final class ByteSourceFile {
        private let source: ArchiveByteSource
        private var offset: Int64 = 0

        init(source: ArchiveByteSource) {
            self.source = source
        }

        func open() throws -> FILEPointer {
            let cookie = Unmanaged.passRetained(self)
            #if os(macOS) || os(iOS) || os(tvOS) || os(visionOS) || os(watchOS) || os(Android)
            guard let result = funopen(cookie.toOpaque(), readStub, nil, seekStub, closeStub)
            else { throw ArchiveError.unreadableArchive }
            #else
            let stubs = cookie_io_functions_t(read: readStub, write: nil, seek: seekStub, close: closeStub)
            guard let result = fopencookie(cookie.toOpaque(), "rb", stubs)
            else { throw ArchiveError.unreadableArchive }
            #endif
            return result
        }
    }
}

private extension Archive.ByteSourceFile {
    func readData(buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard buffer.count > 0 else { return 0 }
        guard self.offset >= 0 else { return 0 }
        let sourceSize = Int64(self.source.size)
        guard self.offset < sourceSize else { return 0 }

        let maxLength = min(buffer.count, Int(sourceSize - self.offset))
        let data = try self.source.read(offset: UInt64(self.offset), length: maxLength)
        guard !data.isEmpty else { return 0 }
        let bytesToCopy = min(data.count, maxLength)
        data.copyBytes(to: buffer.bindMemory(to: UInt8.self), count: bytesToCopy)
        self.offset += Int64(bytesToCopy)
        return bytesToCopy
    }

    func seek(offset: Int64, whence: Int32) -> Int64 {
        let sourceSize = Int64(self.source.size)
        var result: Int64 = -1
        if whence == SEEK_SET {
            result = offset
        } else if whence == SEEK_CUR {
            result = self.offset + offset
        } else if whence == SEEK_END {
            result = sourceSize + offset
        }
        guard result >= 0 && result <= sourceSize else {
            errno = EINVAL
            return -1
        }
        self.offset = result
        return self.offset
    }
}

private func fileFromCookie(cookie: UnsafeRawPointer) -> Archive.ByteSourceFile {
    Unmanaged<Archive.ByteSourceFile>.fromOpaque(cookie).takeUnretainedValue()
}

private func closeStub(_ cookie: UnsafeMutableRawPointer?) -> Int32 {
    if let cookie = cookie {
        Unmanaged<Archive.ByteSourceFile>.fromOpaque(cookie).release()
    }
    return 0
}

#if os(macOS) || os(iOS) || os(tvOS) || os(visionOS) || os(watchOS) || os(Android)

private func readStub(_ cookie: UnsafeMutableRawPointer?,
                      _ bytePtr: UnsafeMutablePointer<Int8>?,
                      _ count: Int32) -> Int32 {
    guard let cookie = cookie, let bytePtr = bytePtr else { return 0 }
    do {
        let bytesRead = try fileFromCookie(cookie: cookie).readData(
            buffer: UnsafeMutableRawBufferPointer(start: bytePtr, count: Int(count))
        )
        return Int32(bytesRead)
    } catch {
        errno = EIO
        return -1
    }
}

private func seekStub(
    _ cookie: UnsafeMutableRawPointer?,
    _ offset: fpos_t,
    _ whence: Int32
) -> fpos_t {
    guard let cookie = cookie else { return -1 }
    return fpos_t(fileFromCookie(cookie: cookie).seek(offset: Int64(offset), whence: whence))
}

#else

private func readStub(
    _ cookie: UnsafeMutableRawPointer?,
    _ bytePtr: UnsafeMutablePointer<Int8>?,
    _ count: Int
) -> Int {
    guard let cookie = cookie, let bytePtr = bytePtr else { return 0 }
    do {
        return try fileFromCookie(cookie: cookie).readData(
            buffer: UnsafeMutableRawBufferPointer(start: bytePtr, count: count)
        )
    } catch {
        errno = EIO
        return -1
    }
}

private func seekStub(
    _ cookie: UnsafeMutableRawPointer?,
    _ offset: UnsafeMutablePointer<Int>?,
    _ whence: Int32
) -> Int32 {
    guard let cookie = cookie, let offset = offset else { return 0 }
    let result = fileFromCookie(cookie: cookie).seek(offset: Int64(offset.pointee), whence: whence)
    if result >= 0 {
        offset.pointee = Int(result)
        return 0
    } else {
        return -1
    }
}

#endif
