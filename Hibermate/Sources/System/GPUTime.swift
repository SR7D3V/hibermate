import Foundation
import HibermateCore
import IOKit

/// Per-process GPU time on Apple silicon, read from the IORegistry without root.
/// Each `AGXDeviceUserClient` under an `IOAccelerator` carries
/// `IOUserClientCreator` ("pid 123, name") and `AppUsage[].accumulatedGPUTime`
/// in nanoseconds.
///
/// This layout is undocumented (macmon and mactop use the same source). If it
/// changes or is absent (Intel Macs), the result is empty and activity
/// watching uses CPU only. That can only make Hibermate hold less, never more.
struct IORegistryGPUTime: GPUTimeSource {
    func gpuTimeByPID() -> [Int32: UInt64] {
        var result: [Int32: UInt64] = [:]
        var accelerators: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &accelerators) == KERN_SUCCESS else {
            return [:]
        }
        defer { IOObjectRelease(accelerators) }

        while case let accelerator = IOIteratorNext(accelerators), accelerator != 0 {
            defer { IOObjectRelease(accelerator) }
            var children: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &children) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(children) }
            while case let client = IOIteratorNext(children), client != 0 {
                defer { IOObjectRelease(client) }
                guard let creator = property(client, "IOUserClientCreator") as? String,
                      let pid = Self.pid(fromCreator: creator),
                      let usage = property(client, "AppUsage") as? [[String: Any]] else { continue }
                let total = usage.reduce(UInt64(0)) { sum, entry in
                    sum &+ ((entry["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0)
                }
                result[pid, default: 0] &+= total
            }
        }
        return result
    }

    private func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// Parses "pid 684, Siri AI" → 684.
    static func pid(fromCreator creator: String) -> Int32? {
        guard creator.hasPrefix("pid ") else { return nil }
        let digits = creator.dropFirst(4).prefix { $0.isNumber }
        return Int32(digits)
    }
}
