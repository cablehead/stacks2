import Foundation

/// Secrets that look the same wherever they're copied from: a terminal, a web
/// page, a note. Text that has one of these shapes is handled as a concealed
/// copy, from any app.
enum SecretShape: String {
    case privateKey = "private key"
    case token = "login token"
    case card = "card number"
    case code = "sign-in code"

    /// The shape of `text`, or nil for ordinary text. A private key counts
    /// anywhere in the text; the others only when they are the whole copy, so
    /// a sentence with a number in it stays ordinary.
    static func match(_ text: String) -> SecretShape? {
        if text.contains("PRIVATE KEY-----"),
           text.range(of: #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----"#, options: .regularExpression) != nil {
            return .privateKey
        }
        let whole = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard whole.count <= 8192 else { return nil }

        // A JWT: three base64url parts, the first a JSON header ("eyJ" is
        // `{"` in base64), optionally after "Bearer ".
        let bare = whole.hasPrefix("Bearer ") ? String(whole.dropFirst(7)) : whole
        if bare.range(of: #"^eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*$"#, options: .regularExpression) != nil {
            return .token
        }

        // A one-time sign-in code: 6 or 8 digits, or 6 split 3 and 3.
        if whole.range(of: #"^(\d{6}|\d{8}|\d{3} \d{3})$"#, options: .regularExpression) != nil {
            return .code
        }

        // A card number: 13 to 19 digits, in groups split by spaces or
        // dashes or not at all, that pass the Luhn check.
        if whole.range(of: #"^\d(?:[ -]?\d){12,18}$"#, options: .regularExpression) != nil,
           luhn(whole.filter(\.isNumber)) {
            return .card
        }
        return nil
    }

    private static func luhn(_ digits: String) -> Bool {
        var sum = 0
        for (i, ch) in digits.reversed().enumerated() {
            guard var d = ch.wholeNumberValue else { return false }
            if i % 2 == 1 {
                d *= 2
                if d > 9 { d -= 9 }
            }
            sum += d
        }
        return sum % 10 == 0 && digits.contains { $0 != "0" }
    }
}
