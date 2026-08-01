// Copyright (C) 2026 miband contributors
//
// This file is part of miband.
//
// miband is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// miband is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
//
// §3 key derivation + §4.2 SPP-V2 encryption (docs/PROTOCOL.md).

import CommonCrypto
import CryptoKit
import Foundation

enum AuthCrypto {
    struct DerivedKeys {
        let decryptionKey: Data // watch -> phone (also verifies the watch's step-2 hmac)
        let encryptionKey: Data // phone -> watch
        let decryptionNonce: Data // unused by SPP-V2/AES-CTR; kept for SPP-V1/AES-CCM parity
        let encryptionNonce: Data
    }

    static func hmacSha256(key: Data, message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }

    /// §3 step 3: innerKey = HMAC-SHA256(phoneNonce||watchNonce, secretKey),
    /// then expand with "miwear-auth"+counter until 64 bytes, then split.
    static func deriveKeys(phoneNonce: Data, watchNonce: Data, secretKey: Data) -> DerivedKeys {
        let innerKey = hmacSha256(key: phoneNonce + watchNonce, message: secretKey)
        var expanded = Data()
        var prev = Data()
        var counter: UInt8 = 1
        while expanded.count < 64 {
            let block = hmacSha256(key: innerKey, message: prev + Data("miwear-auth".utf8) + Data([counter]))
            expanded.append(block)
            prev = block
            counter += 1
        }
        expanded = expanded.prefix(64)
        return DerivedKeys(
            decryptionKey: expanded.subdata(in: 0..<16),
            encryptionKey: expanded.subdata(in: 16..<32),
            decryptionNonce: expanded.subdata(in: 32..<36),
            encryptionNonce: expanded.subdata(in: 36..<40)
        )
    }

    /// §3 step 4: phone must reject the handshake if this doesn't match the
    /// hmac the watch sent alongside its nonce.
    static func confirmWatchHmac(decryptionKey: Data, watchNonce: Data, phoneNonce: Data, watchHmac: Data) -> Bool {
        hmacSha256(key: decryptionKey, message: watchNonce + phoneNonce) == watchHmac
    }

    /// §4.2: AES-128-CTR with the session key reused as *both* the AES key
    /// and the CTR initial counter value. That's a real weakness in the
    /// firmware (flagged in Gadgetbridge's own source as "I wish I was
    /// kidding"), not a mistake here -- replicated verbatim for interop.
    /// CTR is a symmetric stream cipher, so the same call encrypts and
    /// decrypts.
    static func ctrCrypt(key: Data, data: Data) -> Data {
        precondition(key.count == kCCKeySizeAES128)
        let keyBytes = [UInt8](key)
        var cryptor: CCCryptorRef?
        let createStatus = CCCryptorCreateWithMode(
            CCOperation(kCCEncrypt), CCMode(kCCModeCTR),
            CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
            keyBytes, keyBytes, keyBytes.count,
            nil, 0, 0,
            CCModeOptions(kCCModeOptionCTR_BE),
            &cryptor
        )
        precondition(createStatus == kCCSuccess, "CCCryptorCreateWithMode failed: \(createStatus)")
        defer { CCCryptorRelease(cryptor) }

        let input = [UInt8](data)
        var output = [UInt8](repeating: 0, count: input.count)
        var moved = 0
        let updateStatus = CCCryptorUpdate(cryptor, input, input.count, &output, output.count, &moved)
        precondition(updateStatus == kCCSuccess, "CCCryptorUpdate failed: \(updateStatus)")
        return Data(output)
    }

    static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return data
    }
}
