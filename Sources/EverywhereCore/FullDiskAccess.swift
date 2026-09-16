import Foundation
import Darwin

public enum FullDiskAccessStatus: Equatable, Sendable {
    case accessible
    case denied
    case unknown
}

public enum FullDiskAccess {
    public static func check() -> FullDiskAccessStatus {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return probe(paths: [
            home + "/Library/Application Support/com.apple.TCC/TCC.db",
            "/Library/Preferences/com.apple.TimeMachine.plist"
        ])
    }

    static func probe(paths: [String], openFile: (String) -> Int32 = openForProbe) -> FullDiskAccessStatus {
        var denied = false
        for path in paths {
            let error = openFile(path)
            if error == 0 { return .accessible }
            if error == EPERM { denied = true }
        }
        return denied ? .denied : .unknown
    }

    static func openForProbe(_ path: String) -> Int32 {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return errno }
        close(descriptor)
        return 0
    }
}
