import Foundation

public enum AtomicFile {
    public enum Failure: Error, Equatable {
        case write(errno: Int32)
        case rename(errno: Int32)
    }

    /// Writes `data` to a temp file in the destination directory, fsyncs it,
    /// then `rename(2)`s it over `url`. Readers see either the old file or the
    /// new one, never a partial write.
    public static func write(_ data: Data, to url: URL, permissions: mode_t = 0o600) throws {
        let dir = url.deletingLastPathComponent().path
        let tmp = "\(dir)/.\(url.lastPathComponent).\(getpid()).\(UInt32.random(in: 0 ... .max)).tmp"
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, permissions)
        guard fd >= 0 else { throw Failure.write(errno: errno) }
        var ok = data.withUnsafeBytes { buf -> Bool in
            var offset = 0
            while offset < buf.count {
                let n = Darwin.write(fd, buf.baseAddress!.advanced(by: offset), buf.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        let writeErrno = errno
        ok = ok && fsync(fd) == 0
        close(fd)
        guard ok else {
            unlink(tmp)
            throw Failure.write(errno: writeErrno)
        }
        // open() applies the umask; set the intended mode explicitly.
        chmod(tmp, permissions)
        guard rename(tmp, url.path) == 0 else {
            let e = errno
            unlink(tmp)
            throw Failure.rename(errno: e)
        }
    }
}
