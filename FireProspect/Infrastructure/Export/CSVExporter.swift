import Foundation

struct CSVExporter: Sendable {
    static let prospectSchemaVersion = "prospects.v1"
    static let teamSchemaVersion = "team-members.v1"

    enum FormulaInjectionMitigation: Sendable {
        case none
        case prefixApostrophe
    }

    enum ExportError: Error, LocalizedError, Equatable {
        case invalidDestination
        case cannotCreateTemporaryFile(String)
        case encodingFailed
        case writeFailed(String)
        case commitFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidDestination: "Choose a local CSV file destination."
            case .cannotCreateTemporaryFile(let reason): "Could not create the export file: \(reason)"
            case .encodingFailed: "A CSV value could not be encoded as UTF-8."
            case .writeFailed(let reason): "Could not write the CSV: \(reason)"
            case .commitFailed(let reason): "Could not save the completed CSV: \(reason)"
            }
        }
    }

    struct Receipt: Identifiable, Hashable, Sendable {
        enum Schema: String, Hashable, Sendable { case prospects = "prospects.v1", teamMembers = "team-members.v1" }
        let id: UUID
        let schema: Schema
        let destination: URL
        let exportedAt: Timestamp
        let rowCount: Int
    }

    private let mitigation: FormulaInjectionMitigation
    private let fileManager: FileManager

    init(
        mitigation: FormulaInjectionMitigation = .prefixApostrophe,
        fileManager: FileManager = .default
    ) {
        self.mitigation = mitigation
        self.fileManager = fileManager
    }

    static func safeFilename(stem: String, suffix: String = "prospects") -> String {
        let folded = stem.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let safe = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar).lowercased()) : "-"
        }
        let collapsed = String(safe).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return "\(suffix)-\(collapsed.isEmpty ? "export" : String(collapsed.prefix(80))).csv"
    }

    @discardableResult
    func exportProspects(
        _ records: [ProspectRecord],
        to destination: URL,
        exportedAt: Timestamp = .init(rawValue: Date())
    ) throws -> Receipt {
        let formatter = ISO8601DateFormatter()
        try write(to: destination) { writer in
            try writer.row(["schema_version", "exported_at", "prospect_id", "name", "street", "city", "state", "postal_code", "phone", "website", "crawl_status", "relevance_score", "source", "source_query", "discovered_at"])
            for record in records {
                let source = record.provenance.first
                try writer.row([
                    Self.prospectSchemaVersion, formatter.string(from: exportedAt.rawValue), record.id.rawValue,
                    record.name, record.address.street ?? "", record.address.city ?? "", record.address.state ?? "",
                    record.address.postalCode ?? "", record.phoneNumber ?? "", record.websiteURL.absoluteString,
                    record.crawlStatus.rawValue, record.relevance.score.map(String.init) ?? "",
                    source?.source.rawValue ?? "", source?.query ?? "",
                    source.map { formatter.string(from: $0.discoveredAt.rawValue) } ?? ""
                ])
            }
        }
        return Receipt(id: UUID(), schema: .prospects, destination: destination, exportedAt: exportedAt, rowCount: records.count)
    }

    @discardableResult
    func exportTeamMembers(
        _ members: [TeamMember],
        to destination: URL,
        exportedAt: Timestamp = .init(rawValue: Date())
    ) throws -> Receipt {
        let formatter = ISO8601DateFormatter()
        try write(to: destination) { writer in
            try writer.row(["schema_version", "exported_at", "team_member_id", "name", "email", "role", "is_active", "created_at", "updated_at"])
            for member in members {
                try writer.row([
                    Self.teamSchemaVersion, formatter.string(from: exportedAt.rawValue), member.id.rawValue.uuidString,
                    member.name, member.email, member.role, String(member.isActive),
                    formatter.string(from: member.createdAt.rawValue), formatter.string(from: member.updatedAt.rawValue)
                ])
            }
        }
        return Receipt(id: UUID(), schema: .teamMembers, destination: destination, exportedAt: exportedAt, rowCount: members.count)
    }

    private func write(to destination: URL, body: (Writer) throws -> Void) throws {
        guard destination.isFileURL else { throw ExportError.invalidDestination }
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).csv.tmp")
        guard fileManager.createFile(atPath: temporary.path, contents: nil) else {
            throw ExportError.cannotCreateTemporaryFile(temporary.path)
        }

        do {
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            let writer = Writer(handle: handle, mitigation: mitigation)
            try body(writer)
            try handle.synchronize()
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        } catch let error as ExportError {
            try? fileManager.removeItem(at: temporary)
            throw error
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw ExportError.commitFailed(error.localizedDescription)
        }
    }

    private struct Writer {
        let handle: FileHandle
        let mitigation: FormulaInjectionMitigation

        func row(_ values: [String]) throws {
            let line = values.map(field).joined(separator: ",") + "\r\n"
            guard let data = line.data(using: .utf8) else { throw ExportError.encodingFailed }
            do { try handle.write(contentsOf: data) }
            catch { throw ExportError.writeFailed(error.localizedDescription) }
        }

        private func field(_ original: String) -> String {
            var value = original
            if case .prefixApostrophe = mitigation,
               let first = value.drop(while: { $0.isWhitespace }).first,
               "=+-@".contains(first) {
                value = "'" + value
            }
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
    }
}
