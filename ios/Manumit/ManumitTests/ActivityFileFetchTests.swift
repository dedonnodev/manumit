import XCTest
@testable import Manumit

final class ActivityFileFetchTests: XCTestCase {
    func testCRC32MatchesKnownVector() {
        // Standard CRC-32/ISO-HDLC check value for ASCII "123456789" (used to
        // validate every CRC-32 implementation against every other one).
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF43926)
    }

    func testCRC32OfEmptyIsZero() {
        XCTAssertEqual(CRC32.checksum(Data()), 0)
    }

    func testChunkReassemblyAndCrcCheck() {
        // Build a fake file: 7-byte fileId + 1 padding byte + 2 body bytes,
        // then a real CRC32 trailer over all of it, split into two chunks.
        let fileIdBytes = Data([0x64, 0x00, 0x00, 0x00, 0x04, 0x06, 0x00])
        let body = fileIdBytes + Data([0x00]) + Data([0xAA, 0xBB])
        let crc = CRC32.checksum(body)
        var full = body
        full.append(UInt8(crc & 0xFF))
        full.append(UInt8((crc >> 8) & 0xFF))
        full.append(UInt8((crc >> 16) & 0xFF))
        full.append(UInt8((crc >> 24) & 0xFF))

        let fetcher = ActivityFileFetchBuffer()
        // chunk 1/2
        var chunk1 = Data([2, 0, 1, 0]) // total=2, num=1 (LE uint16 each)
        chunk1.append(full.prefix(6))
        XCTAssertNil(fetcher.addChunk(chunk1))
        // chunk 2/2
        var chunk2 = Data([2, 0, 2, 0])
        chunk2.append(full.suffix(from: 6))
        let result = fetcher.addChunk(chunk2)
        XCTAssertEqual(result, full)
    }

    func testBadCrcIsRejected() {
        let fileIdBytes = Data([0x64, 0x00, 0x00, 0x00, 0x04, 0x06, 0x00])
        var full = fileIdBytes + Data([0x00, 0xAA, 0xBB])
        full.append(contentsOf: [0, 0, 0, 0]) // wrong CRC
        let fetcher = ActivityFileFetchBuffer()
        var chunk = Data([1, 0, 1, 0])
        chunk.append(full)
        XCTAssertNil(fetcher.addChunk(chunk))
    }
}
