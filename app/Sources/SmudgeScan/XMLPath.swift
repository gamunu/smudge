// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation

/// Walks an XML document and reports each element with its path of local names (namespace
/// prefixes removed) and its trimmed text.
final class XMLPath: NSObject, XMLParserDelegate {
    private var path: [String] = []
    private var text = ""
    private let onStart: ([String], [String: String]) -> Void
    private let onEnd: ([String], String) -> Void

    private init(onStart: @escaping ([String], [String: String]) -> Void,
                 onEnd: @escaping ([String], String) -> Void) {
        self.onStart = onStart
        self.onEnd = onEnd
    }

    /// Returns false when the document is not well formed.
    @discardableResult
    static func walk(_ data: Data, start: @escaping ([String], [String: String]) -> Void = { _, _ in },
                     end: @escaping ([String], String) -> Void) -> Bool {
        let w = XMLPath(onStart: start, onEnd: end)
        let p = XMLParser(data: data)
        p.delegate = w
        return p.parse()
    }

    static func local(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        path.append(Self.local(elementName))
        text = ""
        var attrs: [String: String] = [:]
        for (k, v) in attributeDict { attrs[Self.local(k)] = v }
        onStart(path, attrs)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        onEnd(path, text.trimmingCharacters(in: .whitespacesAndNewlines))
        path.removeLast()
        text = ""
    }
}
