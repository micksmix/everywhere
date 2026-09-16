import Foundation

struct FilterQuery {
    enum Predicate {
        case extensions(Set<String>)
        case directory(Bool)
        case size(NumericRange)
        case modified(NumericRange)
        case scope(String, recursive: Bool)
    }

    struct Filter {
        let predicate: Predicate
        let negated: Bool

        func matches(name: String, isDirectory: Bool, size: Int64, modified: Double) -> Bool {
            let result: Bool
            switch predicate {
            case .extensions(let extensions): result = !isDirectory && extensions.contains((name as NSString).pathExtension.lowercased())
            case .directory(let directory): result = directory == isDirectory
            case .size(let range): result = !isDirectory && range.contains(Double(size))
            case .modified(let range): result = range.contains(modified)
            case .scope: return true
            }
            return negated ? !result : result
        }
    }

    struct Group {
        let terms: [ParsedTerm]
        let filters: [Filter]
    }

    struct NumericRange {
        var minimum: Double = -.infinity
        var maximum: Double = .infinity
        var includesMinimum = true
        var includesMaximum = true
        var inverted = false

        func contains(_ value: Double) -> Bool {
            let inside = (includesMinimum ? value >= minimum : value > minimum) &&
                (includesMaximum ? value <= maximum : value < maximum)
            return inverted ? !inside : inside
        }
    }

    let groups: [Group]
    static let keys: Set<String> = ["ext", "type", "file", "folder", "size", "dm", "datemodified", "parent", "in", "infolder"]
    static let types: [String: String] = [
        "image": "jpg;jpeg;png;gif;heic;heif;tif;tiff;webp;svg;bmp;avif;raw",
        "audio": "mp3;m4a;aac;wav;flac;ogg;aiff;alac;opus",
        "video": "mov;mp4;m4v;mkv;avi;webm;mpeg;mpg",
        "doc": "pdf;txt;md;rtf;doc;docx;odt;pages",
        "code": "swift;c;h;cpp;hpp;m;mm;rs;go;py;js;jsx;ts;tsx;java;rb;sh;css;html;json;yaml;yml;toml",
        "archive": "zip;gz;tar;tgz;bz2;xz;7z;rar;zst",
        "spreadsheet": "xls;xlsx;csv;tsv;ods;numbers",
        "presentation": "ppt;pptx;odp;key",
        "pdf": "pdf"
    ]

    static func split(_ term: ParsedTerm) -> (String, String)? {
        guard !term.isQuoted, let colon = term.text.firstIndex(of: ":") else { return nil }
        let key = String(term.text[..<colon]).lowercased()
        guard keys.contains(key) else { return nil }
        return (key, String(term.text[term.text.index(after: colon)...]))
    }

    static func isFolderPrefix(_ term: ParsedTerm) -> Bool {
        term.text.hasPrefix("/") && term.endsWithPathSeparator && !term.hasWildcards &&
            !term.text.contains("//") && !term.text.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }

    static func containsFilters(_ text: String) -> Bool {
        SearchQueryParser.parse(text).groups.contains { $0.terms.contains { split($0) != nil || isFolderPrefix($0) } }
    }

    init(_ text: String, now: Date = Date(), calendar: Calendar = .current) throws {
        groups = try SearchQueryParser.parse(text).groups.map { group in
            var terms: [ParsedTerm] = []
            var filters: [Filter] = []
            for term in group.terms {
                guard let (key, value) = Self.split(term) else {
                    if Self.isFolderPrefix(term) {
                        filters.append(Filter(predicate: .scope(String(term.text.dropLast()), recursive: true), negated: term.isNegated))
                    } else { terms.append(term) }
                    continue
                }
                let predicate: Predicate
                switch key {
                case "file", "folder":
                    predicate = .directory(key == "folder")
                    if !value.isEmpty { terms.append(ParsedTerm(text: value, isNegated: false)) }
                    if term.isNegated && !value.isEmpty { throw DatabaseError.invalidQuery("Use !\(key): as a separate filter.") }
                case "ext":
                    let extensions = value.split(separator: ";").map { String($0).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
                    guard !extensions.isEmpty, extensions.allSatisfy({ !$0.isEmpty }) else { throw DatabaseError.invalidQuery("ext: needs an extension, such as ext:pdf;txt.") }
                    predicate = .extensions(Set(extensions))
                case "type":
                    let aliases = ["images": "image", "picture": "image", "pictures": "image", "documents": "doc", "document": "doc", "music": "audio", "archives": "archive", "spreadsheets": "spreadsheet", "presentations": "presentation"]
                    let type = aliases[value.lowercased()] ?? value.lowercased()
                    guard let extensions = Self.types[type] else { throw DatabaseError.invalidQuery("Unknown file type: \(value). Use image, audio, video, doc, code, archive, spreadsheet, presentation, or pdf.") }
                    predicate = .extensions(Set(extensions.split(separator: ";").map(String.init)))
                case "size": predicate = .size(try Self.numberRange(value, convert: Self.sizeValue))
                case "dm", "datemodified": predicate = .modified(try Self.dateRange(value, now: now, calendar: calendar))
                default:
                    let expanded = (value as NSString).expandingTildeInPath
                    guard expanded.hasPrefix("/") else { throw DatabaseError.invalidQuery("\(key): needs an absolute folder path or ~/path.") }
                    predicate = .scope((expanded as NSString).standardizingPath, recursive: key != "parent")
                }
                filters.append(Filter(predicate: predicate, negated: term.isNegated))
            }
            return Group(terms: terms, filters: filters)
        }
    }

    static func numberRange(_ value: String, convert: (String) throws -> Double) throws -> NumericRange {
        if value.contains("..") {
            let parts = value.components(separatedBy: "..")
            guard parts.count == 2 else { throw DatabaseError.invalidQuery("Invalid range: \(value)") }
            let minimum = parts[0].isEmpty ? -Double.infinity : try convert(parts[0])
            let maximum = parts[1].isEmpty ? Double.infinity : try convert(parts[1])
            guard minimum <= maximum else { throw DatabaseError.invalidQuery("Range starts after it ends: \(value)") }
            return NumericRange(minimum: minimum, maximum: maximum)
        }
        let operation = [">=", "<=", "!=", ">", "<", "="].first { value.hasPrefix($0) } ?? ""
        let number = try convert(String(value.dropFirst(operation.count)))
        switch operation {
        case ">": return NumericRange(minimum: number, includesMinimum: false)
        case ">=": return NumericRange(minimum: number)
        case "<": return NumericRange(maximum: number, includesMaximum: false)
        case "<=": return NumericRange(maximum: number)
        default: return NumericRange(minimum: number, maximum: number, inverted: operation == "!=")
        }
    }

    static func sizeValue(_ text: String) throws -> Double {
        if text.lowercased() == "empty" { return 0 }
        let number = text.prefix { $0.isNumber || $0 == "." }
        let unit = text.dropFirst(number.count).lowercased()
        let units: [String: Double] = ["": 1, "b": 1, "k": 1e3, "kb": 1e3, "mb": 1e6, "gb": 1e9, "tb": 1e12,
                                        "kib": 1024, "mib": 1048576, "gib": 1073741824, "tib": 1099511627776]
        guard let amount = Double(number), let multiplier = units[unit], amount.isFinite, amount >= 0,
              (amount * multiplier).isFinite else { throw DatabaseError.invalidQuery("Invalid size: \(text). Try size:>100MB or size:1MiB..10MiB.") }
        return amount * multiplier
    }

    static func dateRange(_ text: String, now: Date, calendar: Calendar) throws -> NumericRange {
        let value = text.lowercased()
        let periods: [String: (Calendar.Component, Int)] = ["today": (.day, 0), "yesterday": (.day, -1),
            "thisweek": (.weekOfYear, 0), "lastweek": (.weekOfYear, -1), "thismonth": (.month, 0),
            "lastmonth": (.month, -1), "thisyear": (.year, 0), "lastyear": (.year, -1)]
        if let (component, offset) = periods[value], let date = calendar.date(byAdding: component, value: offset, to: now),
           let interval = calendar.dateInterval(of: component, for: date) {
            return NumericRange(minimum: interval.start.timeIntervalSince1970, maximum: interval.end.timeIntervalSince1970, includesMaximum: false)
        }
        let rolling: [String: Calendar.Component] = ["pastweek": .weekOfYear, "pastmonth": .month, "pastyear": .year]
        if let component = rolling[value], let start = calendar.date(byAdding: component, value: -1, to: now) {
            return NumericRange(minimum: start.timeIntervalSince1970, maximum: now.timeIntervalSince1970)
        }
        func day(_ text: String) throws -> Date {
            let parts = text.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
                  let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
                  let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
                  calendar.component(.year, from: date) == year, calendar.component(.month, from: date) == month,
                  calendar.component(.day, from: date) == day else { throw DatabaseError.invalidQuery("Invalid date: \(text). Use YYYY-MM-DD or a relative date such as pastweek.") }
            return date
        }
        func end(_ text: String) throws -> Double {
            guard let date = calendar.date(byAdding: .day, value: 1, to: try day(text)) else { throw DatabaseError.invalidQuery("Invalid date: \(text)") }
            return date.timeIntervalSince1970
        }
        if value.contains("..") {
            let parts = value.components(separatedBy: "..")
            guard parts.count == 2 else { throw DatabaseError.invalidQuery("Invalid date range: \(text)") }
            let minimum = parts[0].isEmpty ? -Double.infinity : try day(parts[0]).timeIntervalSince1970
            let maximum = parts[1].isEmpty ? Double.infinity : try end(parts[1])
            guard minimum < maximum else { throw DatabaseError.invalidQuery("Date range starts after it ends.") }
            return NumericRange(minimum: minimum, maximum: maximum, includesMaximum: false)
        }
        let operation = [">=", "<=", "!=", ">", "<", "="].first { value.hasPrefix($0) } ?? ""
        let date = String(value.dropFirst(operation.count))
        let start = try day(date).timeIntervalSince1970
        switch operation {
        case ">": return NumericRange(minimum: try end(date))
        case ">=": return NumericRange(minimum: start)
        case "<": return NumericRange(maximum: start, includesMaximum: false)
        case "<=": return NumericRange(maximum: try end(date), includesMaximum: false)
        default: return NumericRange(minimum: start, maximum: try end(date), includesMaximum: false, inverted: operation == "!=")
        }
    }
}
