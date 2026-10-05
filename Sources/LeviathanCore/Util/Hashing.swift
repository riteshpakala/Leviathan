//
//  Hashing.swift
//  LeviathanCore
//
//  WHAT: SHA-256 as lowercase hex, for prompt hashes and stable ids.
//

import CryptoKit
import Foundation

public enum Hashing {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(_ text: String) -> String {
        sha256Hex(Data(text.utf8))
    }
}
