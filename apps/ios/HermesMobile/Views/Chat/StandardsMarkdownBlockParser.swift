import Foundation
import Markdown

/// Standards-based CommonMark/GFM block parser that feeds Hermes' existing
/// native renderers. It owns syntax interpretation only: images, code, math,
/// selection, links, and visual styling remain native iOS presentation concerns.
@MainActor
enum StandardsMarkdownBlockParser {
    typealias Block = MessageBubble.MarkdownBlock
    typealias TableModel = MessageBubble.MarkdownTable
    typealias TaskItem = MessageBubble.MarkdownTaskItem
    typealias ListItemModel = MessageBubble.MarkdownListItem

    static func parse(_ source: String) -> [Block] {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let document = Document(parsing: source)
        return coalescingAdjacentLists(document.children.flatMap(convert))
    }

    private static func convert(_ markup: any Markup) -> [Block] {
        if let table = markup as? Markdown.Table {
            return [.table(convertTable(table))]
        }
        if let quote = markup as? BlockQuote {
            let body = blockquoteBody(quote)
            if let alert = MessageBubble.markdownAlert(fromBlockquoteText: body) {
                return [.alert(alert)]
            }
            return body.isEmpty ? [] : [.blockquote(body)]
        }
        if let list = markup as? OrderedList {
            return blocks(from: flatten(list, level: sourceIndentationLevel(list)))
        }
        if let list = markup as? UnorderedList {
            return blocks(from: flatten(list, level: sourceIndentationLevel(list)))
        }

        let formatted = trimmed(markup.format())
        return formatted.isEmpty ? [] : [.paragraph(formatted)]
    }

    private static func convertTable(_ table: Markdown.Table) -> TableModel {
        let headers = table.head.children.compactMap { $0 as? Markdown.Table.Cell }.map(cellText)
        let rows = Array(table.body.rows.map { row in
            row.children.compactMap { $0 as? Markdown.Table.Cell }.map(cellText)
        })
        let alignments = table.columnAlignments.map { alignment -> TableModel.Alignment in
            switch alignment {
            case .center: .center
            case .right: .trailing
            case .left, .none: .leading
            }
        }
        return TableModel(headers: headers, alignments: alignments, rows: rows)
    }

    private static func cellText(_ cell: Markdown.Table.Cell) -> String {
        // MarkupFormatter deliberately traps when asked to format a table cell
        // outside its parent table. Re-parent its inline children into a standalone
        // paragraph so emphasis, links, code, and escapes survive for the existing
        // inline renderer without invoking the unsupported cell formatter.
        let paragraph = Paragraph(Array(cell.inlineChildren))
        return trimmed(paragraph.format())
    }

    private enum FlatListEntry {
        case task(TaskItem)
        case item(ListItemModel)
    }

    private static func flatten(_ list: OrderedList, level: Int) -> [FlatListEntry] {
        flatten(items: Array(list.listItems), orderedStart: Int(list.startIndex), level: level)
    }

    private static func flatten(_ list: UnorderedList, level: Int) -> [FlatListEntry] {
        flatten(items: Array(list.listItems), orderedStart: nil, level: level)
    }

    private static func flatten(
        items: [Markdown.ListItem],
        orderedStart: Int?,
        level: Int
    ) -> [FlatListEntry] {
        var output: [FlatListEntry] = []
        for (offset, item) in items.enumerated() {
            let text = item.children
                .filter { !($0 is OrderedList) && !($0 is UnorderedList) }
                .map { trimmed($0.format()) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")

            if let checkbox = item.checkbox {
                output.append(.task(TaskItem(
                    checked: checkbox == .checked,
                    text: text,
                    level: level
                )))
            } else {
                let marker = orderedStart.map { "\($0 + offset)." } ?? "•"
                output.append(.item(ListItemModel(marker: marker, text: text, level: level)))
            }

            for child in item.children {
                if let nested = child as? OrderedList {
                    output.append(contentsOf: flatten(nested, level: level + 1))
                } else if let nested = child as? UnorderedList {
                    output.append(contentsOf: flatten(nested, level: level + 1))
                }
            }
        }
        return output
    }

    /// The existing renderer has distinct list/task block views. Group adjacent
    /// entries of the same kind without losing mixed-list or nesting order.
    private static func blocks(from entries: [FlatListEntry]) -> [Block] {
        var result: [Block] = []
        var tasks: [TaskItem] = []
        var items: [ListItemModel] = []

        func flushTasks() {
            guard !tasks.isEmpty else { return }
            result.append(.taskItems(tasks))
            tasks.removeAll(keepingCapacity: true)
        }
        func flushItems() {
            guard !items.isEmpty else { return }
            result.append(.listItems(items))
            items.removeAll(keepingCapacity: true)
        }

        for entry in entries {
            switch entry {
            case .task(let task):
                flushItems()
                tasks.append(task)
            case .item(let item):
                flushTasks()
                items.append(item)
            }
        }
        flushTasks()
        flushItems()
        return result
    }

    /// cmark correctly treats two-space indentation after an ordered marker as
    /// a new top-level list, while LLM output commonly intends it as a child.
    /// Preserve that source indentation as a presentation level and coalesce the
    /// adjacent list ASTs. Fully-valid CommonMark nesting is already represented
    /// as child lists and follows the recursive path above.
    private static func sourceIndentationLevel(_ markup: any Markup) -> Int {
        guard let column = markup.range?.lowerBound.column, column > 1 else { return 0 }
        return max(0, (column - 1) / 2)
    }

    private static func coalescingAdjacentLists(_ blocks: [Block]) -> [Block] {
        var result: [Block] = []
        for block in blocks {
            switch (result.last, block) {
            case let (.listItems(existing)?, .listItems(incoming)):
                result[result.count - 1] = .listItems(existing + incoming)
            case let (.taskItems(existing)?, .taskItems(incoming)):
                result[result.count - 1] = .taskItems(existing + incoming)
            default:
                result.append(block)
            }
        }
        return result
    }

    private static func blockquoteBody(_ quote: BlockQuote) -> String {
        // LLMs sometimes indent a GitHub alert marker four spaces after `>`.
        // CommonMark correctly parses that as an indented code block, but the
        // established Hermes alert affordance accepts surrounding whitespace.
        // Preserve that narrow compatibility case without weakening parsing for
        // ordinary quoted code blocks.
        if quote.childCount == 1,
           let codeBlock = quote.child(at: 0) as? CodeBlock,
           MessageBubble.markdownAlert(fromBlockquoteText: codeBlock.code) != nil {
            return trimmed(codeBlock.code)
        }
        let lines = quote.format().components(separatedBy: "\n")
        let stripped = lines.compactMap(MessageBubble.blockquoteText)
        return trimmed(stripped.joined(separator: "\n"))
    }

    private static func trimmed(_ string: String) -> String {
        string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
