import Foundation
import SwiftUI

struct MarketAsset: Codable, Identifiable, Hashable {
    var id: String { symbol }
    let symbol: String
    let name: String
    let subtitle: String
    let kind: String
    let price: Double
    let changePercent: Double
    let currency: String
    let volume: String
    let open: Double
    let high: Double
    let low: Double
    let previousClose: Double
    var decimals: Int { kind == "ETF" ? 3 : 2 }
    func formatted(_ value: Double) -> String { String(format: "%.*f", decimals, value) }
    var change: Double { price - previousClose }
}

struct HistoryPoint: Codable, Identifiable {
    var id: String { date }
    let date: String
    let close: Double
    let volume: Double
}

struct ForecastPoint: Codable, Identifiable {
    var id: String { date }
    let date: String
    let p025: Double
    let p10: Double
    let p25: Double
    let p50: Double
    let p75: Double
    let p90: Double
    let p975: Double
    func lower(_ confidence: Int) -> Double { confidence == 95 ? p025 : p10 }
    func upper(_ confidence: Int) -> Double { confidence == 95 ? p975 : p90 }
}

struct Forecast: Codable, Identifiable {
    let id: String
    let horizon: Int
    let points: [ForecastPoint]
    let trend: String
    let upProbability: Double
    let explanation: String
    let drivers: [ForecastDriver]
    let scenarios: [ForecastScenario]
    let usage: ForecastUsage
    let backtest: Backtest
    var last: ForecastPoint { points[points.count - 1] }
}
struct ForecastDriver: Codable, Identifiable {
    var id: String { title }
    let title: String
    let value: String
    let detail: String
    let score: Double
}
struct ForecastScenario: Codable, Identifiable {
    var id: String { name }
    let name: String
    let probability: Double
    let target: Double
    let detail: String
}
struct ForecastUsage: Codable { let inputTokens: Int; let outputTokens: Int; let latencyMs: Int }
struct Backtest: Codable { let coverage: Double; let sampleCount: Int; let medianError: Double; let description: String }
struct MarketSnapshot: Codable {
    let asset: MarketAsset
    let asOf: String
    let source: String
    let model: String
    let history: [HistoryPoint]
    let predictions: [String: Forecast]
}
struct DemoPayload: Codable {
    let assets: [MarketAsset]
    let snapshots: [String: MarketSnapshot]
    let disclaimer: String
}
struct DeliveryReceipt: Codable, Identifiable {
    let id: String
    let predictionId: String
    let symbol: String
    let assetName: String
    let channel: String
    let createdAt: String
    let status: String
    let forecast: DeliveredForecast?
}
struct DeliveredForecast: Codable {
    let horizon: Int
    let confidence: Int
    let lower: Double
    let median: Double
    let upper: Double
    let currency: String
    let decimals: Int
    let explanation: String
    func formatted(_ value: Double) -> String { String(format: "%.*f", decimals, value) }
    init(forecast: Forecast, asset: MarketAsset, confidence: Int) {
        horizon = forecast.horizon
        self.confidence = confidence
        lower = forecast.last.lower(confidence)
        median = forecast.last.p50
        upper = forecast.last.upper(confidence)
        currency = asset.currency
        decimals = asset.decimals
        explanation = forecast.explanation
    }
}

protocol MarketDataService {
    func assets() async throws -> [MarketAsset]
    func snapshot(symbol: String, horizon: Int) async throws -> MarketSnapshot
    func deliver(forecast: Forecast, asset: MarketAsset, confidence: Int, channel: String) async throws -> DeliveryReceipt
}

/// Bundled JSON uses the same contract as the HTTP demo API, allowing fully offline demos.
struct DemoMarketService: MarketDataService {
    private func payload() throws -> DemoPayload {
        guard let url = Bundle.main.url(forResource: "market-demo", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try MarketJSON.decoder.decode(DemoPayload.self, from: Data(contentsOf: url))
    }
    func assets() async throws -> [MarketAsset] { try payload().assets }
    func snapshot(symbol: String, horizon: Int) async throws -> MarketSnapshot {
        try await Task.sleep(for: .milliseconds(240))
        guard let result = try payload().snapshots[symbol] else { throw CocoaError(.coderValueNotFound) }
        return result
    }
    func deliver(forecast: Forecast, asset: MarketAsset, confidence: Int, channel: String) async throws -> DeliveryReceipt {
        try await Task.sleep(for: .milliseconds(400))
        return DeliveryReceipt(id: UUID().uuidString, predictionId: forecast.id, symbol: asset.symbol,
                               assetName: asset.name, channel: channel,
                               createdAt: ISO8601DateFormatter().string(from: Date()), status: "delivered",
                               forecast: DeliveredForecast(forecast: forecast, asset: asset, confidence: confidence))
    }
}

/// Set RWKV_API_BASE_URL in the Xcode scheme environment to switch to an HTTP service.
struct HTTPMarketService: MarketDataService {
    let baseURL: URL
    private func get<T: Decodable>(_ path: String) async throws -> T {
        let (data, response) = try await URLSession.shared.data(from: baseURL.appending(path: path))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try MarketJSON.decoder.decode(T.self, from: data)
    }
    func assets() async throws -> [MarketAsset] { try await get("v1/assets") }
    func snapshot(symbol: String, horizon: Int) async throws -> MarketSnapshot {
        try await get("v1/markets/\(symbol)")
    }
    func deliver(forecast: Forecast, asset: MarketAsset, confidence: Int, channel: String) async throws -> DeliveryReceipt {
        var request = URLRequest(url: baseURL.appending(path: "v1/deliveries"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["prediction_id": forecast.id, "symbol": asset.symbol, "confidence": confidence, "channel": channel])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 201 else { throw URLError(.badServerResponse) }
        return try MarketJSON.decoder.decode(DeliveryReceipt.self, from: data)
    }
}

enum MarketJSON {
    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

@Observable @MainActor
final class MarketViewModel {
    var assets: [MarketAsset] = []
    var snapshot: MarketSnapshot?
    var selectedSymbol = "510300"
    var horizon = 20
    var confidence = 80
    var loading = false
    var errorMessage: String?
    var deliveries: [DeliveryReceipt] = []
    var favorites: Set<String> = []
    private var generation = 0
    private let service: any MarketDataService
    var forecast: Forecast? { snapshot?.predictions[String(horizon)] }
    var isFavorite: Bool { favorites.contains(snapshot?.asset.symbol ?? selectedSymbol) }

    init() {
        if let value = ProcessInfo.processInfo.environment["RWKV_API_BASE_URL"], let url = URL(string: value) {
            service = HTTPMarketService(baseURL: url)
        } else { service = DemoMarketService() }
        favorites = Set(UserDefaults.standard.stringArray(forKey: "favorites") ?? [])
        if let data = UserDefaults.standard.data(forKey: "deliveries"), let saved = try? JSONDecoder().decode([DeliveryReceipt].self, from: data) {
            deliveries = saved
        }
    }
    func load() async {
        generation += 1
        let current = generation
        loading = true
        errorMessage = nil
        defer { if current == generation { loading = false } }
        do {
            if assets.isEmpty { assets = try await service.assets() }
            let result = try await service.snapshot(symbol: selectedSymbol, horizon: horizon)
            guard current == generation else { return }
            guard result.asset.symbol == selectedSymbol, !result.history.isEmpty, [5, 20, 60].allSatisfy({ result.predictions[String($0)]?.points.isEmpty == false }) else {
                throw CocoaError(.coderInvalidValue)
            }
            snapshot = result
        } catch {
            guard current == generation else { return }
            errorMessage = "数据加载失败，请检查服务连接后重试。"
        }
    }
    func toggleFavorite() {
        let symbol = snapshot?.asset.symbol ?? selectedSymbol
        if favorites.contains(symbol) { favorites.remove(symbol) } else { favorites.insert(symbol) }
        UserDefaults.standard.set(Array(favorites), forKey: "favorites")
    }
    func deliver(channel: String) async throws {
        guard let forecast, let asset = snapshot?.asset else { return }
        let receipt = try await service.deliver(forecast: forecast, asset: asset, confidence: confidence, channel: channel)
        deliveries.insert(receipt, at: 0)
        UserDefaults.standard.set(try JSONEncoder().encode(deliveries), forKey: "deliveries")
    }
}
