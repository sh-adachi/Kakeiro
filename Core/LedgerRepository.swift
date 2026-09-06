import Foundation

public struct LedgerRepository: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    /// Only a missing file creates an empty ledger. Unreadable or invalid data throws.
    public func load() throws -> LedgerState {
        let data: Data
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            if let bytes = attributes[.size] as? NSNumber, bytes.int64Value > 128 * 1_024 * 1_024 {
                throw FinanceError.corruptedFile
            }
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return .empty
        } catch let error as FinanceError {
            throw error
        } catch {
            throw FinanceError.fileReadFailed
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let state = try decoder.decode(LedgerState.self, from: data)
            try LedgerValidation.validate(state)
            return state
        } catch let error as FinanceError {
            throw error
        } catch {
            throw FinanceError.corruptedFile
        }
    }

    public func save(_ state: LedgerState) throws {
        try LedgerValidation.validate(state)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .millisecondsSince1970
            let data = try encoder.encode(state)
            let directory = fileURL.deletingLastPathComponent()
            #if os(iOS)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete])
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            #else
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            #endif
        } catch {
            throw FinanceError.fileWriteFailed
        }
    }
}
