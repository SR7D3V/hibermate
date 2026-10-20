import Foundation

/// Identifiers shared by the app and the privileged helper.
public enum HelperIdentity {
    public static let appBundleID = "com.sr7d3v.hibermate"
    public static let helperBundleID = "com.sr7d3v.hibermate.helper"
    /// The launchd label and Mach service name (they're the same).
    public static let machServiceName = "com.sr7d3v.hibermate.helper"
    /// File name of the launchd plist inside `Contents/Library/LaunchDaemons/`.
    public static let launchdPlistName = "com.sr7d3v.hibermate.helper.plist"
    /// The only executable allowed to talk to the helper.
    public static let appExecutablePath = "/Applications/Hibermate.app/Contents/MacOS/Hibermate"

    /// Code-signing requirement for callers. v1 is ad-hoc signed, so there's no
    /// Team ID to pin. With a Developer ID, append
    /// `and anchor apple generic and certificate leaf[subject.OU] = "<TEAMID>"`.
    public static let callerRequirement = #"identifier "com.sr7d3v.hibermate""#
}

/// The helper's entire interface: three methods. None takes caller-supplied
/// strings or commands.
@objc public protocol HibermateHelperXPC {
    /// `true` starts or refreshes a hold. `false` restores the user's original value.
    func setSleepDisabled(_ disabled: Bool, reply: @escaping (_ ok: Bool) -> Void)
    /// Puts the Mac to sleep. The app calls this only after its own safety checks.
    func sleepNow(reply: @escaping (_ ok: Bool) -> Void)
    /// Resets the dead-man timer, and doubles as a reachability ping. It also
    /// passes the app's external-display reading, which the helper uses only to
    /// decide whether it may sleep a lid-closed Mac if the app is lost. Replies
    /// whether the helper currently has a hold recorded.
    func heartbeat(externalDisplayConnected: Bool, reply: @escaping (_ holdActive: Bool) -> Void)
}
