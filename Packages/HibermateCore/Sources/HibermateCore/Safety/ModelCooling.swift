import Foundation

/// Whether a Mac cools passively. This picks the default timeout for sustained
/// `.fair` thermal pressure with the lid closed: 5 min fanless, 10 min with fans.
///
/// THE single source of truth for model identifiers (`sysctl hw.model`).
/// Sources, checked 2026-10-17:
/// - MacBook Air: https://support.apple.com/102869
/// - MacBook Pro: https://support.apple.com/108052
/// - 12-inch MacBook: https://support.apple.com/103257
/// - Base 14-inch M5 MacBook Pro has one fan: https://support.apple.com/123156
///
/// Any identifier not listed here counts as **fanless**, the stricter choice.
/// A brand-new model therefore gets the shorter timeout until it's added here.
public enum ModelCooling {
    /// Apple silicon MacBook Airs and the 12-inch MacBook (Intel Core m): no fan.
    public static let fanless: Set<String> = [
        "MacBookAir10,1",              // MacBook Air (M1, 2020)
        "Mac14,2", "Mac14,15",         // MacBook Air (M2) 13-inch, 15-inch
        "Mac15,12", "Mac15,13",        // MacBook Air (M3) 13-inch, 15-inch
        "Mac16,12", "Mac16,13",        // MacBook Air (M4) 13-inch, 15-inch
        "Mac17,3", "Mac17,4",          // MacBook Air (M5) 13-inch, 15-inch
        "MacBook8,1", "MacBook9,1", "MacBook10,1", // MacBook (Retina, 12-inch)
    ]

    /// Apple silicon MacBook Pros, all of which have fans. Intel MacBook Pros
    /// (`MacBookPro*`) and Intel MacBook Airs (`MacBookAir2,1`…`MacBookAir9,1`) are
    /// matched by prefix in `hasFan(_:)`.
    public static let appleSiliconWithFans: Set<String> = [
        "MacBookPro17,1",                              // 13-inch, M1, 2020
        "MacBookPro18,1", "MacBookPro18,2",            // 16-inch, 2021
        "MacBookPro18,3", "MacBookPro18,4",            // 14-inch, 2021
        "Mac14,7",                                     // 13-inch, M2, 2022
        "Mac14,5", "Mac14,9",                          // 14-inch, 2023
        "Mac14,6", "Mac14,10",                         // 16-inch, 2023
        "Mac15,3", "Mac15,6", "Mac15,8", "Mac15,10",   // 14-inch, Nov 2023
        "Mac15,7", "Mac15,9", "Mac15,11",              // 16-inch, Nov 2023
        "Mac16,1", "Mac16,6", "Mac16,8",               // 14-inch, 2024
        "Mac16,7", "Mac16,5",                          // 16-inch, 2024
        "Mac17,2",                                     // 14-inch, M5
        "Mac17,7", "Mac17,9",                          // 14-inch, M5 Pro / M5 Max
        "Mac17,6", "Mac17,8",                          // 16-inch, M5 Pro / M5 Max
    ]

    public static func hasFan(_ identifier: String) -> Bool {
        if fanless.contains(identifier) { return false }
        if appleSiliconWithFans.contains(identifier) { return true }
        // Every MacBookPro* identifier, Intel or Apple silicon, has a fan.
        if identifier.hasPrefix("MacBookPro") { return true }
        // Intel MacBook Airs (MacBookAir2,1 … MacBookAir9,1) have fans.
        if identifier.hasPrefix("MacBookAir"),
           let major = Int(identifier.dropFirst("MacBookAir".count).prefix { $0.isNumber }),
           (2...9).contains(major) {
            return true
        }
        return false // unknown → treat as fanless (stricter)
    }

    public static func isFanless(_ identifier: String?) -> Bool {
        guard let identifier, !identifier.isEmpty else { return true }
        return !hasFan(identifier)
    }
}
