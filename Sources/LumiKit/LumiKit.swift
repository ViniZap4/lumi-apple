import Foundation

/// Headless core for the Lumi Apple client.
///
/// `LumiKit` MUST NOT import SwiftUI. This module is the platform-agnostic
/// substrate (domain types, filesystem I/O, networking, sync) and stays
/// importable by command-line tools and headless tests.
public enum LumiKit {
    public static let version = "0.1.0"
}
