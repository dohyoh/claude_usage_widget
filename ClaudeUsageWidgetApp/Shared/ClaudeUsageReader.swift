//
//  ClaudeUsageReader.swift
//  Shared between ClaudeUsageWidgetApp (menu bar) and ClaudeUsageWidgetExtension.
//
//  Claude Code가 `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl` 에 남기는
//  대화 로그에서 토큰 사용량을 읽어 5시간 창·일간·주간으로 집계한다.
//

import Foundation

/// 로그 한 줄에서 뽑아낸 요청 하나의 사용량.
struct UsageRecord: Hashable, Sendable {
    let timestamp: Date
    let model: String
    let tokens: TokenCounts
    /// 중복 제거 키. 같은 요청이 여러 줄에 걸쳐 기록되는 경우가 있다.
    let dedupeKey: String
}

/// JSONL 로그를 증분으로 읽어 스냅샷을 만든다.
///
/// 메뉴바 앱은 인스턴스를 유지해 초 단위로 `makeSnapshot()`을 호출하고,
/// 위젯은 타임라인마다 새 인스턴스로 한 번씩 호출한다.
final class ClaudeUsageReader {
    /// 이미 읽은 파일의 위치를 기억해 새로 붙은 부분만 파싱한다.
    private struct FileState {
        var bytesConsumed: UInt64
        var records: [UsageRecord]
    }

    private let projectsDirectory: URL
    private var fileStates: [String: FileState] = [:]

    /// - Parameter claudeHome: 기본값은 `~/.claude`.
    init(claudeHome: URL? = nil) {
        let home = claudeHome ?? ClaudeUsageReader.defaultClaudeHome
        self.projectsDirectory = home.appendingPathComponent("projects", isDirectory: true)
    }

    static var defaultClaudeHome: URL {
        // 샌드박스 안에서 FileManager.homeDirectoryForCurrentUser 는 컨테이너를 가리키므로
        // 실제 홈 경로를 직접 구성한다.
        let real = NSHomeDirectory()
        if real.contains("/Library/Containers/") {
            // ~/Library/Containers/<bundle-id>/Data → ~
            let components = real.components(separatedBy: "/Library/Containers/")
            if let userHome = components.first, !userHome.isEmpty {
                return URL(fileURLWithPath: userHome).appendingPathComponent(".claude", isDirectory: true)
            }
        }
        return URL(fileURLWithPath: real).appendingPathComponent(".claude", isDirectory: true)
    }

    // MARK: - Snapshot

    /// - Parameter bounds: 서버 실측이 알려준 창 경계. 로그만으로는 맞출 수 없는 값이라,
    ///   경계를 모르는 창은 집계를 만들지 않는다.
    func makeSnapshot(now: Date = Date(),
                      bounds: UsageWindowBounds = .unknown) -> UsageSnapshot {
        // 주간 집계 시작점. 서버가 리셋 시각을 알려주지 않았으면 **집계하지 않는다** —
        // 롤링 7일로 근사하면 지난 주기가 섞여 과다 계상된 값이 조용히 화면에 오른다.
        let weeklyStart = bounds.weeklyStart
        // 파일 스캔·보관 범위. 주기 시작이 이 범위 밖이면 주기 앞부분이 조용히 누락되므로
        // 경계보다 한 시간 앞까지 훑는다. 7일은 하한이다 — 5시간 창은 그 안에 늘 들어온다.
        let scanCutoff = min(now.addingTimeInterval(-ClaudeUsageLimits.weeklyWindow),
                            (weeklyStart ?? now).addingTimeInterval(-3600))

        let sessionFiles: [URL]
        do {
            sessionFiles = try discoverSessionFiles(modifiedAfter: scanCutoff)
        } catch {
            var snapshot = UsageSnapshot.empty
            snapshot.generatedAt = now
            snapshot.failureReason = readFailureMessage(for: error)
            return snapshot
        }

        for file in sessionFiles {
            ingest(file: file, keepingRecordsAfter: scanCutoff)
        }
        pruneStates(for: sessionFiles)

        // 같은 요청이 여러 줄에 기록되므로 dedupeKey로 한 번만 센다.
        var seen = Set<String>()
        var weekly = TokenCounts()
        var weeklyByModel: [String: Int] = [:]
        var today = TokenCounts()
        var sessionRecords: [UsageRecord] = []

        let todayStart = Calendar.current.startOfDay(for: now)

        for state in fileStates.values {
            for record in state.records {
                guard record.timestamp >= scanCutoff, record.timestamp <= now else { continue }
                guard seen.insert(record.dedupeKey).inserted else { continue }

                if record.timestamp >= todayStart { today += record.tokens }
                if let sessionStart = bounds.sessionStart, record.timestamp >= sessionStart {
                    sessionRecords.append(record)
                }
                guard let weeklyStart, record.timestamp >= weeklyStart else { continue }
                weekly += record.tokens
                weeklyByModel[record.model, default: 0] += record.tokens.billable
            }
        }

        return UsageSnapshot(generatedAt: now,
                             activeBlock: bounds.sessionStart
                                 .map { block(from: sessionRecords, start: $0) },
                             weeklyTokens: weeklyStart == nil ? nil : weekly,
                             todayTokens: today,
                             weeklyTokensByModel: weeklyStart == nil ? nil : weeklyByModel,
                             scannedSessionCount: sessionFiles.count,
                             failureReason: nil)
    }

    // MARK: - 5시간 창 집계

    /// 시작 시각이 정해진 창 하나를 만든다.
    ///
    /// 시작 시각은 서버가 알려준 리셋 시각에서 역산한 값이다. 로그의 첫 요청 시각으로
    /// 추정하지 않는다 — 창을 여는 요청이 Claude 데스크톱·웹에서 나갔으면 로컬 로그에
    /// 없어 시작이 늦게 잡히고, 그러면 이 창의 요청 수와 토큰이 통째로 모자라게 나온다.
    private func block(from records: [UsageRecord], start: Date) -> SessionBlock {
        var result = SessionBlock(startedAt: start,
                                  lastActivityAt: start,
                                  tokens: TokenCounts(),
                                  requestCount: 0,
                                  tokensByModel: [:])
        for record in records.sorted(by: { $0.timestamp < $1.timestamp }) {
            result.lastActivityAt = record.timestamp
            result.tokens += record.tokens
            result.requestCount += 1
            result.tokensByModel[record.model, default: 0] += record.tokens.billable
        }
        return result
    }

    // MARK: - 파일 탐색

    private func discoverSessionFiles(modifiedAfter cutoff: Date) throws -> [URL] {
        let fm = FileManager.default
        let projectDirs = try fm.contentsOfDirectory(at: projectsDirectory,
                                                    includingPropertiesForKeys: [.isDirectoryKey],
                                                    options: [.skipsHiddenFiles])
        var result: [URL] = []
        for dir in projectDirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let files = (try? fm.contentsOfDirectory(at: dir,
                                                     includingPropertiesForKeys: [.contentModificationDateKey],
                                                     options: [.skipsHiddenFiles])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                // 7일보다 오래 손대지 않은 세션은 주간 집계에 기여하지 않는다.
                let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                if let modified, modified < cutoff { continue }
                result.append(file)
            }
        }
        return result
    }

    private func pruneStates(for currentFiles: [URL]) {
        let live = Set(currentFiles.map(\.path))
        fileStates = fileStates.filter { live.contains($0.key) }
    }

    // MARK: - 증분 파싱

    private func ingest(file: URL, keepingRecordsAfter cutoff: Date) {
        let path = file.path
        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        var state = fileStates[path] ?? FileState(bytesConsumed: 0, records: [])

        // 파일이 줄었다면(회전·재작성) 처음부터 다시 읽는다.
        if size < state.bytesConsumed {
            state = FileState(bytesConsumed: 0, records: [])
        }
        guard size > state.bytesConsumed else {
            state.records.removeAll { $0.timestamp < cutoff }
            fileStates[path] = state
            return
        }

        do {
            try handle.seek(toOffset: state.bytesConsumed)
        } catch {
            return
        }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }

        // 마지막 개행 이후는 아직 쓰는 중일 수 있으니 다음 회차로 넘긴다.
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
        let complete = data[data.startIndex...lastNewline]
        state.bytesConsumed += UInt64(complete.count)

        for line in complete.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            if let record = parseRecord(from: Data(line)), record.timestamp >= cutoff {
                state.records.append(record)
            }
        }
        state.records.removeAll { $0.timestamp < cutoff }
        fileStates[path] = state
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let timestampFormatterNoFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// assistant 응답 한 줄에서 usage를 뽑는다. 그 밖의 줄은 nil.
    private func parseRecord(from line: Data) -> UsageRecord? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let timestampString = object["timestamp"] as? String,
              let timestamp = Self.timestampFormatter.date(from: timestampString)
                  ?? Self.timestampFormatterNoFraction.date(from: timestampString)
        else { return nil }

        let cacheCreation = usage["cache_creation_input_tokens"] as? Int ?? 0
        // 캐시 쓰기는 TTL별 단가가 다르다. 분해가 없으면 1시간으로 본다 —
        // Claude Code는 1시간 TTL을 쓰므로 그쪽이 안전한 추정이다.
        let breakdown = usage["cache_creation"] as? [String: Any]
        let write1h = breakdown?["ephemeral_1h_input_tokens"] as? Int
        let write5m = breakdown?["ephemeral_5m_input_tokens"] as? Int

        var tokens = TokenCounts(input: usage["input_tokens"] as? Int ?? 0,
                                 output: usage["output_tokens"] as? Int ?? 0,
                                 cacheCreation: cacheCreation,
                                 cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0,
                                 cacheCreation1h: write1h ?? (write5m == nil ? cacheCreation : 0),
                                 cacheCreation5m: write5m ?? 0)
        guard tokens.total > 0 else { return nil }

        let model = message["model"] as? String ?? "unknown"
        tokens.costUSD = ModelPricing.cost(model: model, tokens: tokens)
        // requestId 는 재시도·스트리밍으로 여러 줄에 반복되므로 중복 제거 키로 알맞다.
        let dedupeKey = (object["requestId"] as? String)
            ?? (message["id"] as? String)
            ?? (object["uuid"] as? String)
            ?? timestampString

        return UsageRecord(timestamp: timestamp, model: model, tokens: tokens, dedupeKey: dedupeKey)
    }

    private func readFailureMessage(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileReadNoPermissionError || nsError.code == NSFileReadNoSuchFileError {
            return "~/.claude/projects 를 읽을 수 없습니다"
        }
        return nsError.localizedDescription
    }
}

// MARK: - 모델 표시 이름

extension String {
    /// "claude-opus-4-8" → "Opus 4.8" 처럼 위젯에 넣기 좋은 짧은 이름.
    var prettyModelName: String {
        guard hasPrefix("claude-") else { return self }
        let parts = dropFirst("claude-".count).split(separator: "-").map(String.init)
        guard let family = parts.first else { return self }
        let versionParts = parts.dropFirst().filter { Int($0) != nil }
        let name = family.capitalized
        guard !versionParts.isEmpty else { return name }
        return "\(name) \(versionParts.joined(separator: "."))"
    }
}
