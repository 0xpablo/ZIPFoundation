//
//  FileManager+ZIPDeprecated.swift
//  ZIPFoundation
//
//  Created by Thomas Zoechling on 06.02.23.
//

import Foundation

public extension FileManager {

    @available(*, deprecated, renamed: "unzipItem(at:to:skipCRC32:progress:pathEncoding:)")
    func unzipItem(at sourceURL: URL, to destinationURL: URL, skipCRC32: Bool = false,
                   progress: Progress? = nil, preferredEncoding: String.Encoding?) throws {
        try self.unzipItem(at: sourceURL, to: destinationURL, skipCRC32: skipCRC32,
                           progress: progress, pathEncoding: preferredEncoding)
    }

    @available(*, deprecated,
                renamed: "unzipItem(at:to:skipCRC32:symlinksValidWithin:progress:pathEncoding:)")
    func unzipItem(at sourceURL: URL, to destinationURL: URL,
                   skipCRC32: Bool = false, allowUncontainedSymlinks: Bool,
                   progress: Progress? = nil, pathEncoding: String.Encoding? = nil) throws {
        let symlinksValidWithin = allowUncontainedSymlinks ? URL.rootFS : nil
        try self.unzipItem(at: sourceURL, to: destinationURL, skipCRC32: skipCRC32,
                           symlinksValidWithin: symlinksValidWithin,
                           progress: progress, pathEncoding: pathEncoding)
    }
}
