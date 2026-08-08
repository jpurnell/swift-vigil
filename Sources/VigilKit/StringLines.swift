import Foundation

extension StringProtocol {

    /// The text split into lines, however the file that produced it terminated them.
    ///
    /// All three obvious ways to do this in Swift are wrong on a file written on Windows, each
    /// differently:
    ///
    /// | Written as | `"a\r\nb"` becomes |
    /// | --- | --- |
    /// | `split(separator: "\n")` | `["a\r\nb"]` — the whole document, one element |
    /// | `components(separatedBy: "\n")` | `["a\r", "b"]` — a stray return on every line |
    /// | `components(separatedBy: .newlines)` | `["a", "", "b"]` — an empty line per CRLF |
    ///
    /// `"\r\n"` is a single `Character` — one extended grapheme cluster. `split(separator:)`
    /// compares whole `Character`s and never matches it. `components(separatedBy: String)`
    /// searches by scalar, finds the `\n` inside, and leaves the `\r` behind.
    /// `CharacterSet.newlines` holds both scalars and counts them as two separators — which
    /// doubles a Windows file's line count and shifts every line number reported against it.
    ///
    /// `Character.isNewline` is true of CR, LF, CRLF, NEL and the Unicode line separators, and
    /// a CRLF is one `Character`, so this splits each exactly once. Empty subsequences are
    /// kept, so blank lines survive and indexing by line number behaves as
    /// `components(separatedBy:)` did.
    var lines: [String] {
        // Through a concrete `String`: on `StringProtocol` the overload is ambiguous, and the
        // one resolving over unicode scalars would split a CRLF twice.
        let text = String(self)
        return text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
    }
}
