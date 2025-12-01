import Cocoa
import FlutterMacOS
import UniformTypeIdentifiers

enum FilePickerError: Error {
    case readError(message: String)
    case invalidArguments(message: String)
}

public class FilePickerWritablePlugin: NSObject, FlutterPlugin {
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        _ = FilePickerWritablePlugin(with: registrar)
    }
    
    private let channel: FlutterMethodChannel
    private let eventChannel: FlutterEventChannel
    private var _eventSink: FlutterEventSink? = nil
    private var _eventQueue: [[String: String]] = []
    private var isInitialized = false
    private var _initOpen: (url: URL, persistable: Bool)?

    init(with registrar: FlutterPluginRegistrar) {
        channel = FlutterMethodChannel(name: "design.codeux.file_picker_writable", binaryMessenger: registrar.messenger)
        eventChannel = FlutterEventChannel(name: "design.codeux.file_picker_writable/events", binaryMessenger: registrar.messenger)
        super.init()
        registrar.addMethodCallDelegate(self, channel: channel)
        eventChannel.setStreamHandler(self)
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURLEvent(_:with:)), forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleOpenDocumentEvent(_:with:)), forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEOpenDocuments))
    }
    
    deinit {
        NSAppleEventManager.shared().removeEventHandler(forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        NSAppleEventManager.shared().removeEventHandler(forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEOpenDocuments))
    }
    
    private func logDebug(_ message: String) {
        print("DEBUG", "FilePickerWritablePlugin:", message)
        sendEvent(event: ["type": "log", "level": "DEBUG", "message": message])
    }
    
    private func logError(_ message: String) {
        print("ERROR", "FilePickerWritablePlugin:", message)
        sendEvent(event: ["type": "log", "level": "ERROR", "message": message])
    }
    
    @objc
    private func handleURLEvent(_ event: NSAppleEventDescriptor, with replyEvent: NSAppleEventDescriptor) {
        logDebug("Got URL event. \(event)")
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue else { return }
        guard let url = URL(string: urlString) else { return }
        logDebug("Handling URL: \(url)")
        if url.isFileURL {
            _ = _handle(url: url, persistable: true)
        } else {
            channel.invokeMethod("handleUri", arguments: url.absoluteString)
        }
    }
    
    @objc
    private func handleOpenDocumentEvent(_ event: NSAppleEventDescriptor, with replyEvent: NSAppleEventDescriptor) {
        logDebug("Got open document event. \(event)")
        guard let listDescriptor = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else { return }
        for i in 1...listDescriptor.numberOfItems {
            guard let urlDescriptor = listDescriptor.atIndex(i) else { continue }
            guard let urlString = urlDescriptor.stringValue else { continue }
            guard let url = URL(string: urlString) else { continue }
            logDebug("Opening document: \(url)")
            _ = _handle(url: url, persistable: true)
        }
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        do {
            switch call.method {
            case "init":
                isInitialized = true
                if let (openUrl, persistable) = _initOpen {
                    _handleUrl(url: openUrl, persistable: persistable)
                    _initOpen = nil
                }
                result(true)
            case "openFilePicker":
                guard
                    let args = call.arguments as? Dictionary<String, Any>,
                    let allowedExtensions = args["allowedExtensions"] as? String else {
                        throw FilePickerError.invalidArguments(message: "Expected 'args'")
                }
                openFilePicker(allowedExtensions: allowedExtensions, result: result)
            case "openFilePickerForCreate":
                guard
                    let args = call.arguments as? Dictionary<String, Any>,
                    let path = args["path"] as? String else {
                        throw FilePickerError.invalidArguments(message: "Expected 'args'")
                }
                openFilePickerForCreate(path: path, result: result)
            case "readFileWithIdentifier":
                guard
                    let args = call.arguments as? Dictionary<String, Any>,
                    let identifier = args["identifier"] as? String else {
                        throw FilePickerError.invalidArguments(message: "Expected 'identifier'")
                }
                try readFile(identifier: identifier, result: result)
            case "closeFileWithIdentifier":
                guard
                    let args = call.arguments as? Dictionary<String, Any>,
                    let identifier = args["identifier"] as? String else {
                        throw FilePickerError.invalidArguments(message: "Expected 'identifier'")
                }
                try closeFile(identifier: identifier, result: result)
            case "writeFileWithIdentifier":
                guard let args = call.arguments as? Dictionary<String, Any>,
                    let identifier = args["identifier"] as? String,
                    let path = args["path"] as? String else {
                        throw FilePickerError.invalidArguments(message: "Expected 'identifier' and 'path' arguments.")
                }
                try writeFile(identifier: identifier, path: path, result: result)
            case "disposeIdentifier", "disposeAllIdentifiers":
                // macOS doesn't have a concept of disposing identifiers (bookmarks)
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        } catch let error as FilePickerError {
            result(FlutterError(code: "FilePickerError", message: "\(error)", details: nil))
        } catch let error {
            result(FlutterError(code: "UnknownError", message: "\(error)", details: nil))
        }
    }
    
    // MARK: - File Operations
    
    func readFile(identifier: String, result: @escaping FlutterResult) throws {
        guard let bookmark = Data(base64Encoded: identifier) else {
            result(FlutterError(code: "InvalidDataError", message: "Unable to decode bookmark.", details: nil))
            return
        }
        var isStale: Bool = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale)
        logDebug("url: \(url) / isStale: \(isStale)")
        let securityScope = url.startAccessingSecurityScopedResource()
        if !securityScope {
            logDebug("Warning: startAccessingSecurityScopedResource is false for \(url).")
        }
        
        result(_fileInfoResult(tempFile: url, originalURL: url, bookmark: try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)))
    }
    
    func closeFile(identifier: String, result: @escaping FlutterResult) throws {
        guard let bookmark = Data(base64Encoded: identifier) else {
            result(FlutterError(code: "InvalidDataError", message: "Unable to decode bookmark.", details: nil))
            return
        }
        var isStale: Bool = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale)
        logDebug("url: \(url) / isStale: \(isStale)")
        url.stopAccessingSecurityScopedResource()
        result(_fileInfoResult(tempFile: url, originalURL: url, bookmark: bookmark))
    }
    
    func writeFile(identifier: String, path: String, result: @escaping FlutterResult) throws {
        guard let bookmark = Data(base64Encoded: identifier) else {
            throw FilePickerError.invalidArguments(message: "Unable to decode bookmark/identifier.")
        }
        var isStale: Bool = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale)
        logDebug("url: \(url) / isStale: \(isStale)")
        try _writeFile(path: path, destination: url)
        let sourceFile = URL(fileURLWithPath: path)
        result(_fileInfoResult(tempFile: sourceFile, originalURL: url, bookmark: bookmark))
    }
    
    private func _writeFile(path: String, destination: URL) throws {
        let sourceFile = URL(fileURLWithPath: path)
        
        let destAccess = destination.startAccessingSecurityScopedResource()
        if !destAccess {
            logDebug("Warning: startAccessingSecurityScopedResource is false for \(destination) (destination)")
        }
        let sourceAccess = sourceFile.startAccessingSecurityScopedResource()
        if !sourceAccess {
            logDebug("Warning: startAccessingSecurityScopedResource is false for \(sourceFile) (sourceFile)")
        }
        defer {
            if (destAccess) {
                destination.stopAccessingSecurityScopedResource()
            }
            if (sourceAccess) {
                sourceFile.stopAccessingSecurityScopedResource()
            }
        }
        let data = try Data(contentsOf: sourceFile)
        try data.write(to: destination, options: .atomicWrite)
    }
    
    // MARK: - File Picker
    
    func openFilePickerForCreate(path: String, result: @escaping FlutterResult) {
        let sourceFile = URL(fileURLWithPath: path)
        
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = sourceFile.lastPathComponent
        panel.isExtensionHidden = false
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                do {
                    // Copy the source file to the selected destination
                    try self._writeFile(path: path, destination: url)
                    let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                    result(self._fileInfoResult(tempFile: url, originalURL: url, bookmark: bookmark))
                } catch let error {
                    result(FlutterError(code: "ErrorProcessingResult", message: "Error saving file to \(url): \(error)", details: nil))
                }
            } else {
                // User cancelled
                result(nil)
            }
        }
    }

    func openFilePicker(allowedExtensions: String, result: @escaping FlutterResult) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.canCreateDirectories = false
        panel.isExtensionHidden = false
        
        // Configure allowed content types based on extensions
        if #available(macOS 11.0, *) {
            var contentTypes: [UTType] = []
            if allowedExtensions.contains("media") {
                contentTypes = [UTType.audio, UTType.movie]
            } else if allowedExtensions.contains("subtitles") {
                contentTypes = [UTType.item]
            } else if allowedExtensions != "*" {
                // Parse comma-separated extensions
                let extensions = allowedExtensions.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                for ext in extensions {
                    if let utType = UTType(filenameExtension: ext) {
                        contentTypes.append(utType)
                    }
                }
            } else {
                // Allow any file when wildcard is provided
                contentTypes = [UTType.item]
            }
            if contentTypes.isEmpty {
                // Fallback to any file type if no content types were derived
                contentTypes = [UTType.item]
            }
            panel.allowedContentTypes = contentTypes
        } else {
            // Fallback for older macOS versions
            if allowedExtensions.contains("subtitles") || allowedExtensions == "*" {
                panel.allowedFileTypes = nil
            } else if allowedExtensions != "*" && !allowedExtensions.contains("media") {
                let extensions = allowedExtensions.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                panel.allowedFileTypes = extensions
            }
        }
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                do {
                    let fileInfo = try self._prepareUrlForReading(url: url, persistable: true)
                    result(fileInfo)
                } catch let error {
                    result(FlutterError(code: "ErrorProcessingResult", message: "Error handling result url \(url): \(error)", details: nil))
                }
            } else {
                // User cancelled
                result(nil)
            }
        }
    }
    
    // MARK: - URL Handling
    
    private func _handle(url: URL, persistable: Bool) -> Bool {
        if (!isInitialized) {
            _initOpen = (url, persistable)
            return true
        }
        _handleUrl(url: url, persistable: persistable)
        return true
    }
    
    private func _handleUrl(url: URL, persistable: Bool) {
        do {
            if (url.isFileURL) {
                channel.invokeMethod("openFile", arguments: try _prepareUrlForReading(url: url, persistable: persistable)) { result in
                    // Handle completion if needed
                }
            } else {
                channel.invokeMethod("handleUri", arguments: url.absoluteString)
            }
        } catch let error {
            logError("Error handling open url for \(url): \(error)")
            channel.invokeMethod("handleError", arguments: [
                "message": "Error while handling openUrl for isFileURL=\(url.isFileURL): \(error)"
            ])
        }
    }
    
    private func _prepareUrlForReading(url: URL, persistable: Bool) throws -> [String: String] {
        let securityScope = url.startAccessingSecurityScopedResource()
        defer {
            if securityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }
        if !securityScope {
            logDebug("Warning: startAccessingSecurityScopedResource is false for \(url)")
        }
        // Get bookmark for security-scoped access
        let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        return _fileInfoResult(tempFile: url, originalURL: url, bookmark: bookmark, persistable: persistable)
    }
    
    private func _fileInfoResult(tempFile: URL, originalURL: URL, bookmark: Data, persistable: Bool = true) -> [String: String] {
        let identifier = bookmark.base64EncodedString()
        return [
            "path": tempFile.path,
            "identifier": identifier,
            "persistable": "\(persistable)",
            "uri": originalURL.absoluteString,
            "fileName": originalURL.lastPathComponent,
        ]
    }
}

// MARK: - FlutterStreamHandler

extension FilePickerWritablePlugin: FlutterStreamHandler {
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        _eventSink = events
        let queue = _eventQueue
        _eventQueue = []
        for item in queue {
            events(item)
        }
        return nil
    }
    
    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        _eventSink = nil
        return nil
    }
    
    private func sendEvent(event: [String: String]) {
        if let _eventSink = _eventSink {
            _eventSink(event)
        } else {
            _eventQueue.append(event)
        }
    }
}
