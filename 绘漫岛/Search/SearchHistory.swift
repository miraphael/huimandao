import Foundation

/// ──────────────────────────────────────────────────────────────────────────
/// 搜索模块 · 搜索历史
///
/// 原实现**完全没有搜索历史**（grep `searchHistory` 零命中）——
/// 用户每次搜索都要重新打字，这是与参考实现差距最直观的一处。
///
/// 绘漫岛那边是 `SearchComicBeanDao`（GreenDAO/SQLite）存**搜到的漫画**，
/// 本类只存**关键词**（量小、用 UserDefaults 足够），
/// 另外提供「最近搜过的书」轻量缓存给「猜你想搜」用。
/// ──────────────────────────────────────────────────────────────────────────
final class SearchHistory {

    static let shared = SearchHistory()
    private init() { load() }

    private let kKeywords = "hmd_search_history_keywords"
    private let kBooks = "hmd_search_history_books"
    private let maxKeywords = 60
    private let maxBooks = 120

    /// 关键词（最新在前）
    private(set) var keywords: [String] = []
    /// 最近搜到过的书名（用于「猜你想搜」）
    private(set) var books: [String] = []

    private let lock = NSLock()

    // ── 关键词 ──

    /// 记一次搜索。相同关键词会被提到最前（而不是重复插入）。
    func add(_ keyword: String) {
        let k = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        lock.lock()
        keywords.removeAll { $0.caseInsensitiveCompare(k) == .orderedSame }
        keywords.insert(k, at: 0)
        if keywords.count > maxKeywords { keywords = Array(keywords.prefix(maxKeywords)) }
        let snap = keywords
        lock.unlock()
        UserDefaults.standard.set(snap, forKey: kKeywords)
    }

    func remove(_ keyword: String) {
        lock.lock()
        keywords.removeAll { $0 == keyword }
        let snap = keywords
        lock.unlock()
        UserDefaults.standard.set(snap, forKey: kKeywords)
    }

    func clear() {
        lock.lock()
        keywords = []
        lock.unlock()
        UserDefaults.standard.removeObject(forKey: kKeywords)
    }

    /// 「猜你想搜」：按前缀/包含关系给出建议（不含刚输入的那个词本身）
    func suggest(_ input: String, limit: Int = 8) -> [String] {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return Array(keywords.prefix(limit)) }
        lock.lock()
        let snapshot = keywords
        let bookSnapshot = books
        lock.unlock()
        var out: [String] = []
        for k in snapshot where k.lowercased().contains(q) && k.lowercased() != q {
            out.append(k)
            if out.count >= limit { break }
        }
        if out.count < limit {
            for b in bookSnapshot where b.lowercased().contains(q) {
                if !out.contains(b) { out.append(b) }
                if out.count >= limit { break }
            }
        }
        return out
    }

    // ── 最近搜到的书 ──

    func recordBooks(_ names: [String]) {
        guard !names.isEmpty else { return }
        lock.lock()
        for n in names {
            let t = n.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 2, t.count <= 40 else { continue }
            books.removeAll { $0 == t }
            books.insert(t, at: 0)
        }
        if books.count > maxBooks { books = Array(books.prefix(maxBooks)) }
        let snap = books
        lock.unlock()
        UserDefaults.standard.set(snap, forKey: kBooks)
    }

    func clearBooks() {
        lock.lock()
        books = []
        lock.unlock()
        UserDefaults.standard.removeObject(forKey: kBooks)
    }

    private func load() {
        keywords = (UserDefaults.standard.array(forKey: kKeywords) as? [String]) ?? []
        books = (UserDefaults.standard.array(forKey: kBooks) as? [String]) ?? []
    }
}
