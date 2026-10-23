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
    let marketVendor: String?
    let model: String
    let history: [HistoryPoint]
    let predictions: [String: Forecast]
    var isLive: Bool { source == "akshare" }
    var marketSourceLabel: String { isLive ? "AKShare · 日线收盘" : "模拟行情 · 离线演示" }
    var sourceDescription: String {
        isLive ? "行情与历史价格来自 AKShare\(marketVendor == "sina" ? "（新浪备用源，指数成交额暂无）" : "")，采用最近完整交易日收盘数据。预测、解读及回测为模拟，尚未接入 RWKV。" : "当前为离线演示，行情、预测和回测均为模拟数据。"
    }
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
    let marketSource: String?
    let asOf: String?
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
        marketSource = "mock"
        asOf = nil
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
        let endpoint = baseURL.appending(path: path)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(from: endpoint)
        } catch {
            throw MarketServiceError(error: error, endpoint: endpoint)
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MarketServiceError(data: data) }
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
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw MarketServiceError(error: error, endpoint: request.url ?? baseURL)
        }
        guard (response as? HTTPURLResponse)?.statusCode == 201 else { throw MarketServiceError(data: data) }
        return try MarketJSON.decoder.decode(DeliveryReceipt.self, from: data)
    }
}

struct MarketServiceError: LocalizedError {
    let errorDescription: String?
    init(data: Data) {
        errorDescription = (try? JSONSerialization.jsonObject(with: data) as? [String: String])?["error"] ?? "行情服务返回异常，请稍后重试。"
    }
    init(error: Error, endpoint: URL) {
        let urlError = error as? URLError
        if urlError?.code == .cannotConnectToHost || urlError?.code == .cannotFindHost || urlError?.code == .timedOut {
            errorDescription = "无法连接行情服务：\(endpoint.absoluteString)。iPhone 真机请设置电脑的局域网 IP，并确认后端使用 --host 0.0.0.0 启动。"
        } else if urlError?.code == .notConnectedToInternet {
            errorDescription = "无法访问行情服务：\(endpoint.absoluteString)。请确认手机与电脑连接同一 Wi‑Fi，并在系统设置中允许知势访问本地网络。"
        } else if urlError?.code == .appTransportSecurityRequiresSecureConnection {
            errorDescription = "系统阻止访问 \(endpoint.absoluteString)，请使用 HTTPS 服务，或局域网开发地址。"
        } else {
            errorDescription = "行情服务连接失败（\(endpoint.host ?? endpoint.absoluteString)）：\(error.localizedDescription)"
        }
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
    private var service: any MarketDataService
    private(set) var apiBaseURL: String
    var forecast: Forecast? { snapshot?.predictions[String(horizon)] }
    var isFavorite: Bool { favorites.contains(snapshot?.asset.symbol ?? selectedSymbol) }

    init() {
        let environment = ProcessInfo.processInfo.environment
        let value = environment["RWKV_API_BASE_URL"] ?? UserDefaults.standard.string(forKey: "apiBaseURL") ?? "http://127.0.0.1:8787"
        apiBaseURL = value
        if environment["RWKV_DATA_MODE"] == "demo" {
            service = DemoMarketService()
        } else {
            service = HTTPMarketService(baseURL: URL(string: value) ?? URL(string: "http://127.0.0.1:8787")!)
        }
        favorites = Set(UserDefaults.standard.stringArray(forKey: "favorites") ?? [])
        if let data = UserDefaults.standard.data(forKey: "deliveries"), let saved = try? JSONDecoder().decode([DeliveryReceipt].self, from: data) {
            deliveries = saved
        }
    }
    func configureService(_ address: String) async -> Bool {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            errorMessage = "请输入有效的 HTTP 或 HTTPS 服务地址，例如 http://192.168.1.23:8787。"
            return false
        }
        apiBaseURL = url.absoluteString
        UserDefaults.standard.set(apiBaseURL, forKey: "apiBaseURL")
        service = HTTPMarketService(baseURL: url)
        snapshot = nil
        assets = []
        await load()
        return true
    }
    func load() async {
        generation += 1
        let current = generation
        loading = true
        errorMessage = nil
        defer { if current == generation { loading = false } }
        do {
            let updatedAssets = try await service.assets()
            let result = try await service.snapshot(symbol: selectedSymbol, horizon: horizon)
            guard current == generation else { return }
            guard result.asset.symbol == selectedSymbol, !result.history.isEmpty, [5, 20, 60].allSatisfy({ result.predictions[String($0)]?.points.isEmpty == false }) else {
                throw CocoaError(.coderInvalidValue)
            }
            snapshot = result
            assets = updatedAssets
        } catch {
            guard current == generation else { return }
            if snapshot?.asset.symbol != selectedSymbol { snapshot = nil }
            errorMessage = (error as? MarketServiceError)?.errorDescription ?? "行情加载失败，请确认 AKShare 后端已启动并检查网络后重试。"
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
