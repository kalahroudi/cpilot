// SPDX-License-Identifier: Apache-2.0

import AppKit
import Darwin

/// `CPilot --bench` opens and closes the window and the popover ten times each, then sits idle, and prints the memory and
/// CPU it used. It is how "superlight" gets checked: the numbers must return to the baseline and idle CPU must be near zero.
@MainActor
enum Bench {
    static func cpuSeconds() -> Double {
        var u = rusage(); getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
    }

    static func line(_ s: String) { FileHandle.standardOutput.write(Data((s + "\n").utf8)) }

    static func run(delegate: AppDelegate) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            let base = AppMemory.megabytes
            line(String(format: "baseline (menu bar only): %.1f MB", base))
            var window: [Double] = []
            for i in 1...10 {
                delegate.showManager(); try? await Task.sleep(for: .milliseconds(1500))
                let open = AppMemory.megabytes
                delegate.closeManagerForBench(); try? await Task.sleep(for: .milliseconds(1200))
                let closed = AppMemory.megabytes; window.append(closed)
                line(String(format: "window %2d: open %.1f MB, closed %.1f MB", i, open, closed))
            }
            var pop: [Double] = []
            for i in 1...10 {
                delegate.togglePopoverForBench(); try? await Task.sleep(for: .milliseconds(1200))
                let open = AppMemory.megabytes
                delegate.togglePopoverForBench(); try? await Task.sleep(for: .milliseconds(900))
                let closed = AppMemory.megabytes; pop.append(closed)
                line(String(format: "popover %2d: open %.1f MB, closed %.1f MB", i, open, closed))
            }
            let before = cpuSeconds()
            try? await Task.sleep(for: .seconds(15))
            let idle = (cpuSeconds() - before) / 15 * 100
            line(String(format: "idle CPU over 15 s with everything closed: %.2f%%", idle))
            line(String(format: "after 10 window cycles: %.1f MB (baseline %.1f MB, change %+.1f MB)", window.last ?? 0, base, (window.last ?? 0) - base))
            line(String(format: "after 10 popover cycles: %.1f MB (change %+.1f MB)", pop.last ?? 0, (pop.last ?? 0) - base))
            NSApp.terminate(nil)
        }
    }
}
