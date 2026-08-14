import Foundation

/// Company-domain emails that look like a real person, not a shared inbox.
enum SiteEmailPolicy {
    static let genericLocalParts: Set<String> = [
        "info", "sales", "support", "hello", "contact", "office", "admin", "marketing",
        "hr", "jobs", "careers", "webmaster", "noreply", "no-reply", "no_reply",
        "billing", "help", "media", "press", "inquiries", "enquiry", "team", "mail",
        "customerservice", "customer-service", "reception", "general", "ask"
    ]

    static func registrableDomain(from host: String) -> String {
        let host = host.lowercased()
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func emailDomain(_ email: String) -> String? {
        email.split(separator: "@").last.map { String($0).lowercased() }
    }

    static func belongsToSite(_ email: String, siteHost: String) -> Bool {
        guard let domain = emailDomain(email) else { return false }
        let site = registrableDomain(from: siteHost)
        return domain == site || domain == "www.\(site)"
    }

    static func isGenericMailbox(_ email: String) -> Bool {
        let local = email.split(separator: "@").first.map { String($0).lowercased() } ?? ""
        return genericLocalParts.contains(local)
    }

    static func isPersonalCompanyEmail(_ email: String, siteHost: String) -> Bool {
        belongsToSite(email, siteHost: siteHost) && !isGenericMailbox(email)
    }

    static func hasCompanyContacts(_ people: [PersonnelExtraction.Person], siteHost: String) -> Bool {
        people.contains { person in
            guard let email = person.email else { return false }
            return isPersonalCompanyEmail(email, siteHost: siteHost)
        }
    }
}
