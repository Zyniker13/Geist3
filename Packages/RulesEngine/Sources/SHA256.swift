// Pure-Swift SHA-256 (FIPS 180-4). Used for ruleset hashes, the seed
// commitment (§10.3), and final-state hashes (§10.4). Integer-only and
// deterministic, so the engine stays dependency-free and cross-platform.

import Foundation

public struct SHA256 {
    private var state: [UInt32]
    private var buffer: [UInt8] = []
    private var length: UInt64 = 0

    private static let roundConstants: [UInt32] = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
        0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3, 0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
        0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
        0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
        0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13, 0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
        0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
        0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
        0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208, 0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
    ]

    public init() {
        state = [
            0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a,
            0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
        ]
    }

    public mutating func update(data: Data) {
        buffer.append(contentsOf: data)
        length &+= UInt64(data.count)
        while buffer.count >= 64 {
            processBlock(Array(buffer[0..<64]))
            buffer.removeFirst(64)
        }
    }

    public mutating func finalize() -> [UInt8] {
        var padded = buffer
        padded.append(0x80)
        while padded.count % 64 != 56 { padded.append(0) }
        let bits = length &* 8
        for shift in stride(from: 56, through: 0, by: -8) {
            padded.append(UInt8((bits >> UInt64(shift)) & 0xFF))
        }
        var index = 0
        while index < padded.count {
            processBlock(Array(padded[index..<index + 64]))
            index += 64
        }
        var digest: [UInt8] = []
        for word in state {
            digest.append(UInt8((word >> 24) & 0xFF))
            digest.append(UInt8((word >> 16) & 0xFF))
            digest.append(UInt8((word >> 8) & 0xFF))
            digest.append(UInt8(word & 0xFF))
        }
        return digest
    }

    private mutating func processBlock(_ block: [UInt8]) {
        var schedule = [UInt32](repeating: 0, count: 64)
        for wordIndex in 0..<16 {
            let base = wordIndex * 4
            schedule[wordIndex] =
                (UInt32(block[base]) << 24) | (UInt32(block[base + 1]) << 16)
                | (UInt32(block[base + 2]) << 8) | UInt32(block[base + 3])
        }
        for wordIndex in 16..<64 {
            let previous = schedule[wordIndex - 15]
            let sigma0 = rotr(previous, 7) ^ rotr(previous, 18) ^ (previous >> 3)
            let pair = schedule[wordIndex - 2]
            let sigma1 = rotr(pair, 17) ^ rotr(pair, 19) ^ (pair >> 10)
            schedule[wordIndex] = schedule[wordIndex - 16] &+ sigma0 &+ schedule[wordIndex - 7] &+ sigma1
        }
        var workA = state[0]
        var workB = state[1]
        var workC = state[2]
        var workD = state[3]
        var workE = state[4]
        var workF = state[5]
        var workG = state[6]
        var workH = state[7]
        for round in 0..<64 {
            let bigSigma1 = rotr(workE, 6) ^ rotr(workE, 11) ^ rotr(workE, 25)
            let choose = (workE & workF) ^ (~workE & workG)
            let temp1 = workH &+ bigSigma1 &+ choose &+ SHA256.roundConstants[round] &+ schedule[round]
            let bigSigma0 = rotr(workA, 2) ^ rotr(workA, 13) ^ rotr(workA, 22)
            let majority = (workA & workB) ^ (workA & workC) ^ (workB & workC)
            let temp2 = bigSigma0 &+ majority
            workH = workG
            workG = workF
            workF = workE
            workE = workD &+ temp1
            workD = workC
            workC = workB
            workB = workA
            workA = temp1 &+ temp2
        }
        state[0] = state[0] &+ workA
        state[1] = state[1] &+ workB
        state[2] = state[2] &+ workC
        state[3] = state[3] &+ workD
        state[4] = state[4] &+ workE
        state[5] = state[5] &+ workF
        state[6] = state[6] &+ workG
        state[7] = state[7] &+ workH
    }

    @inline(__always)
    private func rotr(_ value: UInt32, _ amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }
}

extension SHA256 {
    /// One-shot convenience.
    public static func digest(_ data: Data) -> [UInt8] {
        var sha = SHA256()
        sha.update(data: data)
        return sha.finalize()
    }
}
