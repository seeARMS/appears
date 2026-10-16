import AppearsCore
import AppearsDownloads
import Foundation

final class DownloadService: NSObject, ModelDownloadXPC {
    let installer: ModelInstaller
    init(installer: ModelInstaller) { self.installer = installer }
    func status(reply: @escaping @Sendable (Data) -> Void) {
        Task { [installer] in reply(try! JSONEncoder().encode(await installer.status())) }
    }
    func start(reply: @escaping @Sendable (Data) -> Void) {
        Task { [installer] in reply(try! JSONEncoder().encode(await installer.start())) }
    }
    func retry(reply: @escaping @Sendable (Data) -> Void) {
        Task { [installer] in reply(try! JSONEncoder().encode(await installer.start(retry: true))) }
    }
}

final class DownloadListener: NSObject, NSXPCListenerDelegate {
    let service = DownloadService(installer: ModelInstaller(descriptor: try! ModelDescriptor.bundled()))
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: ModelDownloadXPC.self)
        connection.exportedObject = service
        connection.invalidationHandler = { exit(0) }
        connection.resume()
        return true
    }
}

xpc_transaction_begin()
let delegate = DownloadListener()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
