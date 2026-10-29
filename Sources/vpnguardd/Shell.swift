import Foundation

@discardableResult
func run(_ path: String, _ args: [String], input: String? = nil) -> (status: Int32, out: String, err: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe(), err = Pipe(), inp = Pipe()
    p.standardOutput = out
    p.standardError = err
    p.standardInput = input == nil ? FileHandle.nullDevice : inp
    do { try p.run() } catch { return (-1, "", "\(error)") }
    if let input {
        inp.fileHandleForWriting.write(Data(input.utf8))
        try? inp.fileHandleForWriting.close()
    }
    let o = out.fileHandleForReading.readDataToEndOfFile()
    let e = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
}

func log(_ s: String) { fputs(s + "\n", stderr) }
