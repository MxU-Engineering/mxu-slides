import Foundation

public enum SyncDeleteHold {
    public enum Verdict: Equatable, Sendable {
        case apply

        case hold(String)
    }

    public static func remote(paused: Bool, usedByLive: @autoclosure () -> Bool) -> Verdict {
        if paused {
            .hold("paused for the service")
        } else if usedByLive() {
            .hold("the live service uses it")
        } else {
            .apply
        }
    }

    public static func local(paused: Bool) -> Verdict {
        paused ? .hold("paused for the service") : .apply
    }

    public static func isHeldLocally(_ key: SyncLedger.Key, in held: [SyncLedger.HeldDelete]) -> Bool {
        held.contains { $0.key == key && $0.side == .local }
    }

    public enum Release: Equatable, Sendable {

        case keep

        case apply

        case drop
    }

    public static func release(
        _ held: SyncLedger.HeldDelete, paused: Bool, usedByLive: @autoclosure () -> Bool, heldHere: Bool,
        currentNamespace: SyncScope?
    ) -> Release {
        switch held.side {
        case .remote:
            if !heldHere {
                .drop
            } else if paused || usedByLive() {
                .keep
            } else {
                .apply
            }
        case .local:
            if paused {
                .keep
            } else if currentNamespace == held.namespace {
                .drop
            } else {
                .apply
            }
        }
    }
}

public enum SyncCheckpoint {
    public static func snapshots(entry: SyncLedger.Entry?, localHeads: [String]) -> Bool {
        if let entry {
            !entry.pending && localHeads == entry.lastPushedHeads
        } else {
            false
        }
    }
}
