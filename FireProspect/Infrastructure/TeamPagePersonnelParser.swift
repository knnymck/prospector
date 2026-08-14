import Foundation

/// Pulls people from a team listing page and from individual profile pages linked under it.
enum TeamPagePersonnelParser {
    static let maximumProfileCount = 40

    static func profileURLs(in html: String, teamPage: URL) -> [URL] {
        guard let host = teamPage.host?.lowercased() else { return [] }
        let teamPath = normalizedPath(teamPage)
        let pattern = #"(?is)<a\b[^>]*href\s*=\s*[\"']([^\"'#]+)[\"']"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var seen = Set<String>()
        var urls: [URL] = []

        for match in expression.matches(in: html, range: range) {
            guard let hrefRange = Range(match.range(at: 1), in: html) else { continue }
            let href = String(html[hrefRange]).replacingOccurrences(of: "&amp;", with: "&")
            guard let url = URL(string: href, relativeTo: teamPage)?.absoluteURL,
                  url.host?.lowercased() == host,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.fragment = nil
            components?.query = nil
            guard let normalized = components?.url else { continue }
            let path = normalizedPath(normalized)
            guard path != teamPath,
                  path.hasPrefix(teamPath + "/"),
                  looksLikePersonSlug(String(path.dropFirst(teamPath.count + 1)).split(separator: "/").first.map(String.init) ?? ""),
                  seen.insert(normalized.absoluteString).inserted else { continue }
            urls.append(normalized)
            if urls.count == maximumProfileCount { break }
        }
        return urls
    }

    static func childPages(in sitemap: [URL], under teamPage: URL) -> [URL] {
        let teamPath = normalizedPath(teamPage)
        guard let host = teamPage.host?.lowercased() else { return [] }
        var seen = Set<String>()
        return sitemap.compactMap { url -> URL? in
            guard url.host?.lowercased() == host else { return nil }
            let path = normalizedPath(url)
            guard path != teamPath, path.hasPrefix(teamPath + "/") else { return nil }
            let key = path
            guard seen.insert(key).inserted else { return nil }
            return url
        }
    }

    static func headerFooterPeople(in html: String, siteHost: String) -> [PersonnelExtraction.Person] {
        let decoded = decodeHTMLEntities(html)
        let sections = headerFooterSections(in: decoded)
        let emails = sections.flatMap { companyEmails(in: $0, siteHost: siteHost) }
        return merging(emails.map { PersonnelExtraction.Person(email: $0) })
    }

    static func people(in html: String, pageURL: URL) -> [PersonnelExtraction.Person] {
        let decoded = decodeHTMLEntities(html)
        if isLikelyProfilePage(html: decoded, pageURL: pageURL) {
            if let person = personFromProfilePage(html: decoded, pageURL: pageURL) {
                return [person]
            }
        }
        return peopleFromListingPage(html: decoded)
    }

    static func merging(_ people: [PersonnelExtraction.Person]) -> [PersonnelExtraction.Person] {
        var merged: [PersonnelExtraction.Person] = []
        for person in people {
            guard person.name != nil || person.email != nil else { continue }
            if let index = merged.firstIndex(where: { isSamePerson($0, person) }) {
                merged[index] = PersonnelExtraction.Person(
                    name: preferred(merged[index].name, person.name),
                    title: preferred(merged[index].title, person.title),
                    email: preferred(merged[index].email, person.email),
                    phone: preferred(merged[index].phone, person.phone)
                )
            } else {
                merged.append(person)
            }
        }
        return merged
    }

    static func decodeHTMLEntities(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.count)
        var index = string.startIndex
        while index < string.endIndex {
            if string[index] == "&", let end = string[index...].firstIndex(of: ";") {
                let entity = String(string[index...end])
                if let scalar = decodeEntity(entity) {
                    result.unicodeScalars.append(scalar)
                    index = string.index(after: end)
                    continue
                }
            }
            result.append(string[index])
            index = string.index(after: index)
        }
        return result
    }

    static func email(fromMailto href: String) -> String? {
        let decoded = decodeHTMLEntities(href.replacingOccurrences(of: "&amp;", with: "&"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard decoded.lowercased().hasPrefix("mailto:") else { return nil }
        return normalizeEmail(String(decoded.dropFirst(7)))
    }

    static func phone(fromTel href: String) -> String? {
        let raw = decodeHTMLEntities(href.replacingOccurrences(of: "&amp;", with: "&"))
        guard raw.lowercased().hasPrefix("tel:") else { return nil }
        let number = String(raw.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        return number.isEmpty ? nil : number
    }

    // MARK: - Private

    private static func personFromProfilePage(html: String, pageURL: URL) -> PersonnelExtraction.Person? {
        let name = firstMatch(#"(?is)<h1\b[^>]*>(.*?)</h1>"#, in: html).flatMap(visibleText)
            ?? openGraphTitle(in: html)
            ?? nameFromSlug(pageURL)
        let title = firstHeading(in: html, tags: ["h2", "h3"], skipping: [name, "our team", "meet the team", "leadership"])
        let email = firstMailto(in: html)
        let phone = preferredPhone(in: html)
        guard name != nil || email != nil else { return nil }
        return PersonnelExtraction.Person(name: name, title: title, email: email, phone: phone)
    }

    private static func peopleFromListingPage(html: String) -> [PersonnelExtraction.Person] {
        let pattern = #"(?is)<a\b[^>]*href\s*=\s*[\"'](mailto:[^\"']+)[\"'][^>]*>(.*?)</a>"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return mailtoOnlyPeople(in: html) }
        let range = NSRange(html.startIndex..., in: html)
        var people: [PersonnelExtraction.Person] = []
        for match in expression.matches(in: html, range: range) {
            guard let hrefRange = Range(match.range(at: 1), in: html),
                  let matchRange = Range(match.range, in: html),
                  let email = email(fromMailto: String(html[hrefRange])) else { continue }
            let contextStart = html.index(matchRange.lowerBound, offsetBy: -400, limitedBy: html.startIndex) ?? html.startIndex
            let contextEnd = html.index(matchRange.upperBound, offsetBy: 200, limitedBy: html.endIndex) ?? html.endIndex
            let context = String(html[contextStart..<contextEnd])
            let label = Range(match.range(at: 2), in: html).flatMap { visibleText(String(html[$0])) }
            let name = firstHeading(in: context, tags: ["h1", "h2", "h3", "h4", "strong"], skipping: ["email", "contact"])
                ?? label.flatMap { $0.contains("@") ? nil : $0 }
            let title = firstHeading(in: context, tags: ["h3", "h4", "p"], skipping: [name, "email", "our team"])
            let phone = preferredPhone(in: context)
            people.append(.init(name: name, title: title, email: email, phone: phone))
        }
        return merging(people + mailtoOnlyPeople(in: html))
    }

    private static func mailtoOnlyPeople(in html: String) -> [PersonnelExtraction.Person] {
        mailtoHrefs(in: html).compactMap { href in
            email(fromMailto: href).map { PersonnelExtraction.Person(name: nil, title: nil, email: $0, phone: nil) }
        }
    }

    private static func isLikelyProfilePage(html: String, pageURL: URL) -> Bool {
        let path = normalizedPath(pageURL)
        let segments = path.split(separator: "/").map(String.init)
        if segments.count >= 2, looksLikePersonSlug(segments.last ?? "") { return true }
        return html.range(of: #"(?is)<h1\b"#, options: .regularExpression) != nil && firstMailto(in: html) != nil
    }

    private static func looksLikePersonSlug(_ slug: String) -> Bool {
        let slug = slug.lowercased()
        let blocked: Set<String> = ["page", "pages", "feed", "embed", "category", "tag", "author", "wp-json", "wp-content", "oembed"]
        if slug.isEmpty || blocked.contains(slug) { return false }
        if slug.contains(".") { return false }
        return slug.range(of: #"^[a-z][a-z0-9-]{1,80}$"#, options: .regularExpression) != nil
    }

    private static func normalizedPath(_ url: URL) -> String {
        let path = url.path.lowercased()
        if path.count > 1, path.hasSuffix("/") { return String(path.dropLast()) }
        return path.isEmpty ? "/" : path
    }

    private static func isSamePerson(_ lhs: PersonnelExtraction.Person, _ rhs: PersonnelExtraction.Person) -> Bool {
        if let left = lhs.email?.lowercased(), let right = rhs.email?.lowercased(), left == right { return true }
        if let left = lhs.name?.lowercased(), let right = rhs.name?.lowercased(), left == right { return true }
        return false
    }

    private static func preferred(_ first: String?, _ second: String?) -> String? {
        if let first, !first.isEmpty { return first }
        if let second, !second.isEmpty { return second }
        return nil
    }

    private static func firstMailto(in html: String) -> String? {
        mailtoHrefs(in: html).lazy.compactMap(email(fromMailto:)).first
    }

    private static func mailtoHrefs(in html: String) -> [String] {
        let pattern = #"(?i)href\s*=\s*[\"'](mailto:[^\"']+)[\"']"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return expression.matches(in: html, range: range).compactMap { match in
            Range(match.range(at: 1), in: html).map { String(html[$0]) }
        }
    }

    private static func preferredPhone(in html: String) -> String? {
        let pattern = #"(?i)href\s*=\s*[\"'](tel:[^\"']+)[\"']"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        var counts: [String: Int] = [:]
        var order: [String] = []
        for match in expression.matches(in: html, range: range) {
            guard let hrefRange = Range(match.range(at: 1), in: html),
                  let phone = phone(fromTel: String(html[hrefRange])) else { continue }
            if counts[phone] == nil { order.append(phone) }
            counts[phone, default: 0] += 1
        }
        return order.first(where: { (counts[$0] ?? 0) == 1 }) ?? order.first
    }

    private static func firstHeading(in html: String, tags: [String], skipping names: [String?]) -> String? {
        let skipped = Set(names.compactMap { $0?.lowercased() }.filter { !$0.isEmpty } + ["our team", "meet the team"])
        for tag in tags {
            let pattern = "(?is)<\(tag)\\b[^>]*>(.*?)</\(tag)>"
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(html.startIndex..., in: html)
            for match in expression.matches(in: html, range: range) {
                guard let inner = Range(match.range(at: 1), in: html),
                      let text = visibleText(String(html[inner])),
                      !skipped.contains(text.lowercased()),
                      text.count <= 80,
                      !text.contains("@") else { continue }
                return text
            }
        }
        return nil
    }

    private static func firstMatch(_ pattern: String, in html: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = expression.firstMatch(in: html, range: range),
              let inner = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[inner])
    }

    private static func openGraphTitle(in html: String) -> String? {
        let pattern = #"(?is)<meta\s+property=["']og:title["']\s+content=["']([^"']+)["']"#
        guard let raw = firstMatch(pattern, in: html) else { return nil }
        let cleaned = raw.components(separatedBy: " - ").first?.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func nameFromSlug(_ url: URL) -> String? {
        let slug = normalizedPath(url).split(separator: "/").last.map(String.init) ?? ""
        guard looksLikePersonSlug(slug) else { return nil }
        let name = slug.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
        return name.isEmpty ? nil : name
    }

    private static func visibleText(_ html: String) -> String? {
        let withoutTags = html.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        let collapsed = withoutTags.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }

    private static func normalizeEmail(_ raw: String) -> String? {
        let value = raw.split(separator: "?").first.map(String.init) ?? raw
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.contains("@"), trimmed.count <= 120 else { return nil }
        return trimmed
    }

    private static func headerFooterSections(in html: String) -> [String] {
        let pattern = #"(?is)<(nav|header|footer)\b[^>]*>(.*?)</\1\s*>"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return expression.matches(in: html, range: range).compactMap { match in
            Range(match.range(at: 2), in: html).map { String(html[$0]) }
        }
    }

    private static func companyEmails(in html: String, siteHost: String) -> [String] {
        var emails: [String] = []
        var seen = Set<String>()
        for href in mailtoHrefs(in: html) {
            if let email = email(fromMailto: href), SiteEmailPolicy.isPersonalCompanyEmail(email, siteHost: siteHost), seen.insert(email).inserted {
                emails.append(email)
            }
        }
        let pattern = #"(?i)\b[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}\b"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return emails }
        let range = NSRange(html.startIndex..., in: html)
        for match in expression.matches(in: html, range: range) {
            guard let inner = Range(match.range, in: html) else { continue }
            let email = String(html[inner]).lowercased()
            if SiteEmailPolicy.isPersonalCompanyEmail(email, siteHost: siteHost), seen.insert(email).inserted {
                emails.append(email)
            }
        }
        return emails
    }

    private static func decodeEntity(_ entity: String) -> Unicode.Scalar? {
        if entity == "&amp;" { return Unicode.Scalar(38) }
        if entity == "&lt;" { return Unicode.Scalar(60) }
        if entity == "&gt;" { return Unicode.Scalar(62) }
        if entity == "&quot;" { return Unicode.Scalar(34) }
        if entity == "&apos;" { return Unicode.Scalar(39) }
        if entity.hasPrefix("&#x") || entity.hasPrefix("&#X"),
           let value = UInt32(entity.dropFirst(3).dropLast(), radix: 16) {
            return Unicode.Scalar(value)
        }
        if entity.hasPrefix("&#"),
           let value = UInt32(entity.dropFirst(2).dropLast()) {
            return Unicode.Scalar(value)
        }
        return nil
    }
}
