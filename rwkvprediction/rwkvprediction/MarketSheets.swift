import SwiftUI

struct AssetPicker: View {
    @Bindable var model: MarketViewModel
    var favoritesOnly = false
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var category = "全部"
    var filtered: [MarketAsset] {
        model.assets.filter {
            (!favoritesOnly || model.favorites.contains($0.symbol)) &&
            (category == "全部" || $0.kind == category) &&
            (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.symbol.contains(query))
        }
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Picker("市场分类", selection: $category) { Text("全部").tag("全部"); Text("ETF").tag("ETF"); Text("指数").tag("指数") }
                    .pickerStyle(.segmented).padding(.horizontal, 20)
                if filtered.isEmpty {
                    ContentUnavailableView(favoritesOnly ? "还没有自选标的" : "没有找到相关标的", systemImage: favoritesOnly ? "star" : "magnifyingglass", description: Text(favoritesOnly ? "点击行情右侧的星标，即可添加自选。" : "试试输入 ETF 名称或证券代码。"))
                } else {
                    List(filtered) { asset in
                        Button {
                            model.selectedSymbol = asset.symbol
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack { Text(asset.name).font(.system(size: 16, weight: .semibold)); Text(asset.kind).font(.system(size: 9)).foregroundStyle(Design.orange).padding(4).background(Design.orangeSoft, in: RoundedRectangle(cornerRadius: 4)) }
                                    Text(asset.symbol + " · " + asset.subtitle).font(.system(size: 11)).foregroundStyle(Design.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 7) {
                                    Text(asset.formatted(asset.price)).font(.system(size: 17, weight: .semibold, design: .rounded))
                                    Text(String(format: "%+.2f%%", asset.changePercent)).font(.system(size: 11, design: .monospaced))
                                }.foregroundStyle(asset.changePercent >= 0 ? Design.red : Design.green)
                                if model.selectedSymbol == asset.symbol { Image(systemName: "checkmark").foregroundStyle(Design.orange).font(.system(size: 12, weight: .bold)) }
                            }.padding(.vertical, 10).foregroundStyle(Design.ink)
                        }.accessibilityIdentifier("asset-\(asset.symbol)").listRowSeparatorTint(Design.line)
                    }.listStyle(.plain)
                }
                Text(model.snapshot?.marketSourceLabel ?? "行情来源：AKShare").font(.caption2).foregroundStyle(Design.secondary).padding(.bottom, 10)
            }.background(Design.surface)
                .searchable(text: $query, prompt: "搜索 ETF、指数或代码")
                .navigationTitle(favoritesOnly ? "我的自选" : "选择预测标的").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.tint(Design.orange) } }
        }.presentationDragIndicator(.visible)
    }
}

struct DeliverySheet: View {
    @Bindable var model: MarketViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var channel = "in_app"
    @State private var sending = false
    @State private var sent = false
    @State private var error: String?
    private var report: String {
        guard let asset = model.snapshot?.asset, let forecast = model.forecast else { return "" }
        return "【知势 · RWKV 模拟预测】\n\(asset.name) \(asset.symbol)\n收盘价格：\(asset.formatted(asset.price)) CNY\n行情截至：\(model.snapshot?.asOf ?? "")\n未来 \(forecast.horizon) 个交易日\n\(model.confidence)% 期末区间：\(asset.formatted(forecast.last.lower(model.confidence))) – \(asset.formatted(forecast.last.upper(model.confidence)))\n中位预期：\(asset.formatted(forecast.last.p50))\n\n\(forecast.explanation)\n\n\(model.snapshot?.sourceDescription ?? "")\n不构成投资建议。"
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if sent {
                        VStack(spacing: 14) {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(Design.green)
                            Text("预测已下发").font(.title2.bold())
                            Text(channel == "in_app" ? "已保存到站内消息，可在下发记录中查看。" : "已保存演示 Webhook 记录。\n当前不会向外部系统发送请求。")
                                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
                        }.frame(maxWidth: .infinity).padding(.vertical, 36)
                    } else {
                        HStack(spacing: 12) {
                            Image(systemName: "paperplane.fill").font(.title2).foregroundStyle(Design.orange).frame(width: 48, height: 48).background(Design.orangeSoft, in: RoundedRectangle(cornerRadius: 13))
                            VStack(alignment: .leading, spacing: 6) { Text("把洞察，送到下一步").font(.headline); Text("包含走势区间、市场解读与数据来源").font(.caption).foregroundStyle(.secondary) }
                        }
                        Text(report).font(.system(size: 13)).lineSpacing(7).frame(maxWidth: .infinity, alignment: .leading).padding(18).background(Design.canvas, in: RoundedRectangle(cornerRadius: 14))
                        VStack(alignment: .leading, spacing: 12) {
                            Text("下发渠道").font(.subheadline.bold())
                            deliveryOption("站内消息", detail: "生成记录，保存到当前设备", icon: "tray", value: "in_app")
                            deliveryOption("Webhook · 演示", detail: "展示系统集成下发流程", icon: "link", value: "webhook_demo")
                        }
                        if let error { Text(error).font(.caption).foregroundStyle(Design.red) }
                        Button {
                            sending = true
                            Task {
                                do { try await model.deliver(channel: channel); withAnimation { sent = true } }
                                catch { self.error = "下发失败，请检查连接后重试。" }
                                sending = false
                            }
                        } label: {
                            HStack(spacing: 9) { if sending { ProgressView().tint(Design.onAction) }; Text(sending ? "正在下发…" : "确认下发") }
                                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Design.onAction).frame(maxWidth: .infinity).frame(height: 49)
                                .background(Design.action, in: RoundedRectangle(cornerRadius: 12))
                        }.disabled(sending)
                    }
                    ShareLink(item: report) {
                        Label("分享预测摘要", systemImage: "square.and.arrow.up").font(.subheadline).foregroundStyle(Design.orange).frame(maxWidth: .infinity)
                    }
                }.padding(24)
            }.navigationTitle("下发预测").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.tint(Design.orange) } }
        }.presentationDragIndicator(.visible)
    }
    private func deliveryOption(_ title: String, detail: String, icon: String, value: String) -> some View {
        Button { channel = value } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 18)).frame(width: 24)
                VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 14, weight: .medium)); Text(detail).font(.system(size: 11)).foregroundStyle(.secondary) }
                Spacer()
                Image(systemName: channel == value ? "checkmark.circle.fill" : "circle").foregroundStyle(channel == value ? Design.orange : Design.secondary.opacity(0.5))
            }.foregroundStyle(Design.ink).padding(15)
                .background(channel == value ? Design.orangeSoft.opacity(0.6) : Design.canvas, in: RoundedRectangle(cornerRadius: 11))
        }.buttonStyle(.plain)
    }
}

struct DeliveryHistory: View {
    let model: MarketViewModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Group {
                if model.deliveries.isEmpty {
                    ContentUnavailableView("暂无下发记录", systemImage: "tray", description: Text("在预测页面点击「下发预测」，即可保存第一份市场洞察。"))
                } else {
                    List(model.deliveries) { receipt in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack { Text(receipt.assetName).font(.headline); Spacer(); Label("演示下发成功", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(Design.green) }
                            Text(receipt.channel == "in_app" ? "站内消息 · 已保存" : "Webhook · 演示记录").font(.subheadline).foregroundStyle(.secondary)
                            Text(receipt.predictionId).font(.system(size: 10, design: .monospaced)).foregroundStyle(Design.secondary)
                            Text(receipt.createdAt).font(.caption2).foregroundStyle(Design.secondary)
                            if let forecast = receipt.forecast {
                                DisclosureGroup("查看预测内容") {
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text("未来 \(forecast.horizon) 个交易日 · \(forecast.confidence)% 区间").font(.caption)
                                        Text("\(forecast.formatted(forecast.lower)) – \(forecast.formatted(forecast.upper)) \(forecast.currency)").font(.system(size: 17, weight: .semibold, design: .rounded))
                                        Text("中位预期：" + forecast.formatted(forecast.median)).font(.caption)
                                        Text(forecast.explanation).font(.caption).lineSpacing(5)
                                        Text(forecast.marketSource == "akshare" ? "行情：AKShare · 预测与解读：模拟" : "行情与预测均为模拟数据").font(.caption2).foregroundStyle(Design.orange)
                                        if let asOf = forecast.asOf { Text("行情截至：" + asOf).font(.caption2).foregroundStyle(.secondary) }
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                                }.font(.caption).tint(Design.orange)
                            }
                        }.padding(.vertical, 10)
                    }.listStyle(.insetGrouped)
                }
            }.navigationTitle("下发记录").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.tint(Design.orange) } }
        }.presentationDragIndicator(.visible)
    }
}

struct CostSheet: View {
    let usage: ForecastUsage?
    @Environment(\.dismiss) private var dismiss
    @State private var inputPrice = "1.00"
    @State private var outputPrice = "2.00"
    @State private var calls = "10000"
    private var perCall: Double {
        (Double(inputPrice) ?? 0) * Double(usage?.inputTokens ?? 0) / 1_000_000 +
        (Double(outputPrice) ?? 0) * Double(usage?.outputTokens ?? 0) / 1_000_000
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("模型", value: "RWKV · Demo")
                    LabeledContent("输入 Token", value: "\(usage?.inputTokens ?? 0)")
                    LabeledContent("输出 Token", value: "\(usage?.outputTokens ?? 0)")
                    LabeledContent("模拟耗时", value: "\(usage?.latencyMs ?? 0) ms")
                } header: { Text("本次推理用量 · 模拟") } footer: { Text("用量与耗时为演示值，需接入实际 RWKV 推理后实测。") }
                Section {
                    priceField("输入 / 百万 Token（元）", value: $inputPrice)
                    priceField("输出 / 百万 Token（元）", value: $outputPrice)
                    priceField("预计每日调用次数", value: $calls)
                } header: { Text("填写内部核算单价") } footer: { Text("默认单价仅为计算示例，不代表 RWKV 官方报价。仅计算推理 Token 成本，不含行情服务、服务器和存储费用。") }
                Section("估算结果") {
                    LabeledContent("单次推理", value: String(format: "¥ %.6f", perCall))
                    LabeledContent("每日预算", value: String(format: "¥ %.2f", perCall * max(Double(calls) ?? 0, 0)))
                    LabeledContent("每月预算（30日）", value: String(format: "¥ %.2f", perCall * max(Double(calls) ?? 0, 0) * 30))
                }
            }.navigationTitle("推理成本估算").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.tint(Design.orange) } }
        }.presentationDragIndicator(.visible)
    }
    private func priceField(_ title: String, value: Binding<String>) -> some View {
        HStack { Text(title).font(.system(size: 13)); Spacer(); TextField("0", text: value).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 80) }
    }
}
