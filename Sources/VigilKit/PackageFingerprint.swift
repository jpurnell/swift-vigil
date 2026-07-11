import Foundation
import Crypto

/// A digest of a package's sources + manifest — the "same code" key that
/// makes a cross-run outcome flip meaningful (a changed package legitimately
/// changes outcomes; that is not a flip).
public enum PackageFingerprint {

    /// SHA-256 over the manifest and every `.swift` file under `Sources/`
    /// and `Tests/`, in sorted relative-path order (path + content both
    /// feed the hash, so renames count as change).
    ///
    /// - Parameter root: Package root.
    /// - Returns: A hex digest; stable for identical trees.
    public static func compute(root: String) -> String {
        var hasher = SHA256()
        let rootURL = URL(fileURLWithPath: root)

        var files: [String] = ["Package.swift"]
        for dir in ["Sources", "Tests"] {
            let base = rootURL.appendingPathComponent(dir)
            guard let enumerator = FileManager.default.enumerator(atPath: base.path) else { continue } // SAFETY: read-only walk
            while let relative = enumerator.nextObject() as? String {
                guard relative.hasSuffix(".swift") else { continue }
                files.append("\(dir)/\(relative)")
            }
        }

        for relative in files.sorted() {
            let url = rootURL.appendingPathComponent(relative)
            guard let data = FileManager.default.contents(atPath: url.path) else { continue } // SAFETY: unreadable files simply don't feed the hash
            hasher.update(data: Data(relative.utf8))
            hasher.update(data: data)
        }

        return hasher.finalize().map { byte in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0" + hex : hex
        }.joined()
    }
}
