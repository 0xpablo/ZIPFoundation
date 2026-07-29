//
//  Archive+EOCDDataScan.swift
//  ZIPFoundation
//
//  Copyright © 2017-2025 Thomas Zoechling, https://www.peakstep.com and the ZIP Foundation project authors.
//  Released under the MIT License.
//
//  See https://github.com/weichsel/ZIPFoundation/blob/master/LICENSE for license information.
//

import Foundation

extension Archive {
    static func scanForEndOfCentralDirectoryRecord(
        in data: Data,
        dataOffset: UInt64,
        fileSize: UInt64
    ) -> (EndOfCentralDirectoryRecord, UInt64)? {
        guard data.count >= EndOfCentralDirectoryRecord.size else { return nil }

        let signature: UInt32 = UInt32(endOfCentralDirectoryStructSignature)
        let maxStartIndex = data.count - EndOfCentralDirectoryRecord.size
        for index in stride(from: maxStartIndex, through: 0, by: -1) {
            let potentialSignature: UInt32 = data.scanValue(start: index)
            guard potentialSignature == signature else { continue }

            let commentLength: UInt16 = data.scanValue(start: index + 20)
            let endIndex = index + EndOfCentralDirectoryRecord.size + Int(commentLength)
            guard endIndex <= data.count else { continue }
            guard dataOffset + UInt64(endIndex) == fileSize else { continue }

            let fixedRange = index..<index + EndOfCentralDirectoryRecord.size
            let fixedData = data.subdata(in: fixedRange)
            guard let eocd = EndOfCentralDirectoryRecord(
                data: fixedData,
                additionalDataProvider: { additionalSize in
                    let commentStart = index + EndOfCentralDirectoryRecord.size
                    let commentEnd = commentStart + additionalSize
                    guard commentEnd <= data.count else { throw ArchiveError.unreadableArchive }
                    return data.subdata(in: commentStart..<commentEnd)
                }
            ) else { continue }

            return (eocd, dataOffset + UInt64(index))
        }
        return nil
    }
}
