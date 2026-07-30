//
//  ModelPricing.swift
//  Shared between ClaudeUsageWidgetApp (menu bar) and ClaudeUsageWidgetExtension.
//
//  한도를 비용 기준으로 추정하기 위한 모델별 단가.
//  캐시 읽기는 입력의 0.1배로 훨씬 싸지만 양이 수십 배라 총액에서 가장 큰 몫을 차지한다.
//

import Foundation

/// 100만 토큰당 USD 단가.
struct ModelPrice: Sendable {
    let input: Double
    let output: Double

    /// 캐시 쓰기는 TTL에 따라 입력 단가의 배수가 다르다.
    var cacheWrite1h: Double { input * 2.0 }
    var cacheWrite5m: Double { input * 1.25 }
    /// 캐시 읽기는 입력 단가의 약 1/10.
    var cacheRead: Double { input * 0.1 }
}

enum ModelPricing {
    /// 모델 ID 접두사 → 단가. `claude-opus-5[1m]` 처럼 접미사가 붙어도 매칭된다.
    /// 1M 컨텍스트에는 별도 프리미엄이 없어 접미사를 무시해도 된다.
    private static let table: [(prefix: String, price: ModelPrice)] = [
        ("claude-fable-5",   ModelPrice(input: 10, output: 50)),
        ("claude-mythos-5",  ModelPrice(input: 10, output: 50)),
        ("claude-opus-5",    ModelPrice(input: 5,  output: 25)),
        ("claude-opus-4-8",  ModelPrice(input: 5,  output: 25)),
        ("claude-opus-4-7",  ModelPrice(input: 5,  output: 25)),
        ("claude-opus-4-6",  ModelPrice(input: 5,  output: 25)),
        ("claude-opus-4-5",  ModelPrice(input: 5,  output: 25)),
        ("claude-sonnet-5",  ModelPrice(input: 3,  output: 15)),
        ("claude-sonnet-4-6", ModelPrice(input: 3, output: 15)),
        ("claude-sonnet-4-5", ModelPrice(input: 3, output: 15)),
        ("claude-haiku-4-5", ModelPrice(input: 1,  output: 5)),
    ]

    /// 표에 없는 모델은 Opus 단가로 본다 — 과소평가보다 과대평가가 안전하다.
    private static let fallback = ModelPrice(input: 5, output: 25)

    static func price(for model: String) -> ModelPrice {
        for entry in table where model.hasPrefix(entry.prefix) {
            return entry.price
        }
        return fallback
    }

    /// 요청 하나의 USD 비용.
    static func cost(model: String, tokens: TokenCounts) -> Double {
        let p = price(for: model)
        return Double(tokens.input) * p.input / 1_000_000
            + Double(tokens.output) * p.output / 1_000_000
            + Double(tokens.cacheCreation1h) * p.cacheWrite1h / 1_000_000
            + Double(tokens.cacheCreation5m) * p.cacheWrite5m / 1_000_000
            + Double(tokens.cacheRead) * p.cacheRead / 1_000_000
    }
}
