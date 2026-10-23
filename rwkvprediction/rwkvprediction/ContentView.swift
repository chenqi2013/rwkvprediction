import SwiftUI

struct ContentView: View {
    @Environment(\.openURL) private var openURL
    @AppStorage("darkModeEnabled") private var darkModeEnabled = true
    @State private var model = MarketViewModel()
    @State private var activeTab = "AI 预测"
    @State private var bottomTab = "预测"
    @State private var showAssets = false
    @State private var showDelivery = false
    @State private var showMethod = false
    @State private var showHistory = false
    @State private var showCost = false
    @State private var showConnection = false
    @State private var serviceAddress = ""
    @State private var toast: String?
    private let sections = ["行情", "AI 预测", "市场解读"]

    var body: some View {
        VStack(spacing: 0) {
            navigation
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    if let snapshot = model.snapshot, let forecast = model.forecast {
                        quote(snapshot)
                        sectionTabs
                        VStack(spacing: 14) {
                            if activeTab == "行情" {
                                historyCard(snapshot, forecast)
                                marketDetails(snapshot.asset)
                            } else if activeTab == "市场解读" {
                                insightCard(forecast, expanded: true)
                                scenarioCard(snapshot.asset, forecast)
                                evaluationCard(forecast)
                            } else {
                                forecastCard(snapshot, forecast)
                                insightCard(forecast)
                                scenarioCard(snapshot.asset, forecast)
                                evaluationCard(forecast)
                            }
                            sourceFooter
                        }
                        .padding(16)
                    } else if !model.loading {
                        ContentUnavailableView("暂时无法加载行情", systemImage: "wifi.exclamationmark", description: Text(model.errorMessage ?? "请稍后重试"))
                        Button("重新加载") { Task { await model.load() } }.tint(Design.orange)
                        Button("设置行情服务地址") { openConnection() }.tint(Design.orange).padding(.top, 12)
                    } else {
                        ProgressView("正在加载市场数据…").tint(Design.orange).padding(.top, 150)
                    }
                }
            }
            .refreshable { await model.load() }
            bottomNavigation
        }
        .background(Design.canvas)
        .foregroundStyle(Design.ink)
        .task { await model.load() }
        .onChange(of: model.selectedSymbol) { _, _ in Task { await model.load() } }
        .sheet(isPresented: $showAssets, onDismiss: { bottomTab = "预测" }) { AssetPicker(model: model, favoritesOnly: bottomTab == "自选") }
        .sheet(isPresented: $showDelivery) { DeliverySheet(model: model) }
        .sheet(isPresented: $showMethod) { methodSheet }
        .sheet(isPresented: $showHistory) { DeliveryHistory(model: model) }
        .sheet(isPresented: $showCost) { CostSheet(usage: model.forecast?.usage) }
        .sheet(isPresented: $showConnection) { connectionSheet }
        .overlay(alignment: .top) {
            if let toast {
                Text(toast).font(.system(size: 13, weight: .medium)).padding(.horizontal, 18).padding(.vertical, 12)
                    .background(Design.action, in: Capsule()).foregroundStyle(Design.onAction).padding(.top, 60)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .top) {
            if let error = model.errorMessage, model.snapshot != nil {
                HStack { Text(error); Button("重试") { Task { await model.load() } } }
                    .font(.caption).padding(12).background(Design.orangeSoft).padding(.top, 58)
            }
        }
        .preferredColorScheme(darkModeEnabled ? .dark : .light)
    }

    private var navigation: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.path")
                .font(.system(size: 19, weight: .bold)).foregroundStyle(Design.onAction)
                .frame(width: 33, height: 33).background(Design.action, in: RoundedRectangle(cornerRadius: 10))
            Text("知势").font(.system(size: 23, weight: .bold))
            Text("RWKV").font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1).foregroundStyle(Design.secondary).padding(.top, 6)
            Spacer()
            Button { openConnection() } label: { Image(systemName: "gearshape").font(.system(size: 19)) }
                .accessibilityLabel("设置行情服务地址").frame(width: 32, height: 40)
            Button { showHistory = true } label: {
                Image(systemName: "tray").font(.system(size: 20)).overlay(alignment: .topTrailing) {
                    if !model.deliveries.isEmpty { Circle().fill(Design.orange).frame(width: 6, height: 6).offset(x: 3, y: -2) }
                }
            }.accessibilityLabel("下发记录").frame(width: 36, height: 40)
            Button { showAssets = true } label: { Image(systemName: "magnifyingglass").font(.system(size: 21)) }
                .accessibilityLabel("搜索 ETF 和指数").frame(width: 32, height: 40)
        }
        .padding(.horizontal, 20).padding(.vertical, 9).background(Design.surface)
    }

    private func openConnection() {
        serviceAddress = model.apiBaseURL
        showConnection = true
    }

    private var connectionSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $darkModeEnabled) {
                        Label("暗色模式", systemImage: "moon.fill")
                    }
                    .tint(Design.orange)
                    .accessibilityIdentifier("dark-mode-toggle")
                } header: {
                    Text("外观")
                } footer: {
                    Text("默认使用暗色模式，切换后自动保存。")
                }
                Section("行情服务地址") {
                    TextField("http://192.168.1.23:8787", text: $serviceAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .accessibilityIdentifier("market-service-address")
                }
                Section {
                    Text("iPhone 真机请填写运行后端的电脑局域网地址。127.0.0.1 指向手机自身，只适用于模拟器。")
                    Text("手机与电脑需连接同一 Wi‑Fi，并允许本地网络访问。电脑上的后端需使用 --host 0.0.0.0 启动。")
                    Button("打开系统设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }.tint(Design.orange)
                }.font(.subheadline)
                if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(Design.red) }
                Button(model.loading ? "正在连接…" : "保存并连接") {
                    Task {
                        if await model.configureService(serviceAddress) { showConnection = false }
                    }
                }.disabled(model.loading).tint(Design.orange)
            }
            .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showConnection = false } } }
        }
        .preferredColorScheme(darkModeEnabled ? .dark : .light)
    }

    private func quote(_ snapshot: MarketSnapshot) -> some View {
        let asset = snapshot.asset
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Button { showAssets = true } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 7) {
                            Text(asset.name).font(.system(size: 21, weight: .semibold))
                            Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(Design.secondary)
                        }
                        HStack(spacing: 6) {
                            Text(asset.kind == "ETF" ? "SH/SZ" : "INDEX")
                                .font(.system(size: 8, weight: .bold)).padding(.horizontal, 4).padding(.vertical, 2)
                                .background(Design.canvas, in: RoundedRectangle(cornerRadius: 3))
                            Text(asset.symbol).font(.system(size: 11, design: .monospaced))
                            Text(asset.subtitle.components(separatedBy: " · ").first ?? "").font(.system(size: 11))
                        }.foregroundStyle(Design.secondary)
                    }
                }.buttonStyle(.plain).accessibilityLabel("切换标的，当前\(asset.name)")
                Spacer()
                Button {
                    model.toggleFavorite()
                    showToast(model.isFavorite ? "已加入自选" : "已移出自选")
                } label: {
                    Image(systemName: model.isFavorite ? "star.fill" : "star")
                        .font(.system(size: 21)).foregroundStyle(model.isFavorite ? Design.orange : Design.secondary)
                        .frame(width: 35, height: 35)
                }.accessibilityLabel(model.isFavorite ? "移出自选" : "加入自选")
            }
            HStack(alignment: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text(asset.formatted(asset.price)).font(.system(size: 38, weight: .semibold, design: .rounded)).tracking(-1.2)
                        Image(systemName: asset.changePercent >= 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    HStack(spacing: 10) {
                        Text(String(format: "%+.*f", asset.decimals, asset.change))
                        Text(String(format: "%+.2f%%", asset.changePercent))
                    }.font(.system(size: 13, weight: .medium, design: .monospaced))
                }.foregroundStyle(asset.changePercent >= 0 ? Design.red : Design.green)
                Spacer()
                VStack(alignment: .trailing, spacing: 7) {
                    HStack(spacing: 4) {
                        Circle().fill(Design.secondary).frame(width: 4, height: 4)
                        Text(snapshot.isLive ? "日线收盘" : "演示收盘").font(.system(size: 10))
                    }.foregroundStyle(Design.secondary)
                    Text(timestamp(snapshot.asOf, format: "MM/dd HH:mm") + " · 北京时间").font(.system(size: 10)).foregroundStyle(Design.secondary)
                    Text(snapshot.marketSourceLabel).font(.system(size: 9, weight: .medium)).foregroundStyle(Design.orange)
                        .padding(.horizontal, 6).padding(.vertical, 3).background(Design.orangeSoft, in: RoundedRectangle(cornerRadius: 4))
                }.padding(.bottom, 2)
            }
        }.padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 14).background(Design.surface)
        .opacity(model.loading ? 0.5 : 1)
        .allowsHitTesting(!model.loading)
    }

    private var sectionTabs: some View {
        HStack(spacing: 27) {
            ForEach(sections, id: \.self) { tab in
                Button { withAnimation(.easeInOut(duration: 0.2)) { activeTab = tab } } label: {
                    VStack(spacing: 10) {
                        HStack(spacing: 4) {
                            Text(tab).font(.system(size: 15, weight: activeTab == tab ? .semibold : .regular))
                            if tab == "AI 预测" { Text("BETA").font(.system(size: 7, weight: .bold, design: .monospaced)).foregroundStyle(Design.orange).offset(y: -5) }
                        }.foregroundStyle(activeTab == tab ? Design.ink : Design.secondary)
                        Capsule().fill(activeTab == tab ? Design.orange : .clear).frame(width: 24, height: 3)
                    }
                }.buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 22).padding(.top, 5).background(Design.surface)
    }

    private func forecastCard(_ snapshot: MarketSnapshot, _ forecast: Forecast) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 7) {
                Text("走势预测").font(.system(size: 18, weight: .semibold))
                engineBadge
                Spacer()
                Button { showMethod = true } label: { Image(systemName: "info.circle").font(.system(size: 15)).foregroundStyle(Design.secondary) }
                    .accessibilityLabel("预测方法与区间说明")
            }
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 9))
                Text("数据截至 " + timestamp(snapshot.asOf, format: "yyyy/MM/dd HH:mm"))
                Spacer()
                Text("模拟预测").foregroundStyle(Design.orange)
            }.font(.system(size: 10)).foregroundStyle(Design.secondary)
            HStack {
                HStack(spacing: 3) {
                    ForEach([5, 20, 60], id: \.self) { days in
                        Button { withAnimation(.easeInOut(duration: 0.25)) { model.horizon = days } } label: {
                            Text("\(days)日").font(.system(size: 12, weight: model.horizon == days ? .semibold : .regular))
                                .frame(width: 48, height: 29)
                                .background(model.horizon == days ? Design.selectedSurface : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .foregroundStyle(model.horizon == days ? Design.ink : Design.secondary)
                                .shadow(color: .black.opacity(model.horizon == days ? 0.04 : 0), radius: 2, y: 1)
                        }.buttonStyle(.plain).accessibilityLabel("预测未来\(days)个交易日")
                    }
                }.padding(3).background(Design.canvas, in: RoundedRectangle(cornerRadius: 9))
                Spacer()
                Menu {
                    Button("80% 预测区间") { model.confidence = 80 }
                    Button("95% 预测区间") { model.confidence = 95 }
                } label: {
                    HStack(spacing: 4) { Text("\(model.confidence)% 区间"); Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)) }
                        .font(.system(size: 11)).foregroundStyle(Design.secondary)
                }
            }
            HStack(spacing: 7) {
                Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .semibold))
                Text(forecast.trend).font(.system(size: 13, weight: .semibold))
                Rectangle().fill(Design.green.opacity(0.22)).frame(width: 1, height: 11).padding(.horizontal, 3)
                Text("上涨概率").font(.system(size: 11))
                Text(String(format: "%.0f%%", forecast.upProbability*100)).font(.system(size: 12, weight: .bold, design: .rounded))
            }.foregroundStyle(Design.green)
            ForecastChart(snapshot: snapshot, forecast: forecast, confidence: model.confidence)
                .frame(height: 174).padding(.top, -4)
            HStack(spacing: 15) {
                legend("历史走势", color: Design.blue)
                legend("中位走势", color: Design.orange, dashed: true)
                HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(Design.orange.opacity(0.20)).frame(width: 10, height: 7); Text("\(model.confidence)% 预测区间") }
                    .font(.system(size: 9)).foregroundStyle(Design.secondary)
            }.frame(maxWidth: .infinity).padding(.top, -9)
            HStack(spacing: 0) {
                forecastMetric("区间下沿", value: snapshot.asset.formatted(forecast.last.lower(model.confidence)), detail: percent(forecast.last.lower(model.confidence), snapshot.asset.price), color: Design.green)
                Rectangle().fill(Design.line).frame(width: 1, height: 37)
                forecastMetric("中位预期", value: snapshot.asset.formatted(forecast.last.p50), detail: percent(forecast.last.p50, snapshot.asset.price), color: Design.orange)
                Rectangle().fill(Design.line).frame(width: 1, height: 37)
                forecastMetric("区间上沿", value: snapshot.asset.formatted(forecast.last.upper(model.confidence)), detail: percent(forecast.last.upper(model.confidence), snapshot.asset.price), color: Design.red)
            }.padding(.vertical, 12).background(Design.canvas.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 6) {
                Image(systemName: "clock").font(.system(size: 10))
                Text("未来 \(forecast.horizon) 个交易日 · 期末价格区间")
                Spacer()
            }.font(.system(size: 10)).foregroundStyle(Design.secondary)
        }.padding(18).card()
    }

    private func insightCard(_ forecast: Forecast, expanded: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles").font(.system(size: 15)).foregroundStyle(Design.orange)
                Text("读懂这次预测").font(.system(size: 16, weight: .semibold))
                Spacer()
                if !expanded {
                    Button { activeTab = "市场解读" } label: {
                        HStack(spacing: 3) { Text("完整解读"); Image(systemName: "chevron.right").font(.system(size: 9)) }.font(.system(size: 10)).foregroundStyle(Design.secondary)
                    }
                }
            }
            Text(forecast.explanation).font(.system(size: 12)).foregroundStyle(Design.bodyText).lineSpacing(6).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 7) {
                ForEach(Array(forecast.drivers.enumerated()), id: \.offset) { index, driver in
                    HStack(spacing: 4) {
                        Circle().fill(index == 2 ? Design.orange : Design.green).frame(width: 4, height: 4)
                        Text(driver.title + " " + driver.value)
                    }.font(.system(size: 9)).foregroundStyle(index == 2 ? Design.orange : Design.green)
                        .padding(.horizontal, 7).padding(.vertical, 7)
                        .background((index == 2 ? Design.orange : Design.green).opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                }
            }
            if expanded {
                Divider().overlay(Design.line)
                ForEach(forecast.drivers) { driver in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack { Text(driver.title).fontWeight(.medium); Spacer(); Text(driver.value).foregroundStyle(Design.orange) }.font(.system(size: 13))
                        Text(driver.detail).font(.system(size: 12)).foregroundStyle(Design.secondary).lineSpacing(4)
                    }.padding(.vertical, 5)
                }
            }
        }.padding(18).card()
    }

    private func scenarioCard(_ asset: MarketAsset, _ forecast: Forecast) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("三种市场情景").font(.system(size: 16, weight: .semibold)); Spacer(); Text("期末目标 · CNY").font(.system(size: 10)).foregroundStyle(Design.secondary) }
            ForEach(Array(forecast.scenarios.enumerated()), id: \.offset) { index, scenario in
                let color = index == 0 ? Design.red : index == 1 ? Design.orange : Design.green
                HStack(alignment: .center, spacing: 11) {
                    RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3, height: 29)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 7) { Text(scenario.name).font(.system(size: 12, weight: .medium)); Text(String(format: "%.0f%%", scenario.probability*100)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Design.secondary) }
                        Text(scenario.detail).font(.system(size: 10)).foregroundStyle(Design.secondary)
                    }
                    Spacer(minLength: 1)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(asset.formatted(scenario.target)).font(.system(size: 16, weight: .semibold, design: .rounded))
                        Text(percent(scenario.target, asset.price)).font(.system(size: 10, design: .monospaced))
                    }.foregroundStyle(color)
                }
                if index < 2 { Divider().overlay(Design.line) }
            }
        }.padding(18).card()
    }

    private func evaluationCard(_ forecast: Forecast) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack { Text("预测表现").font(.system(size: 16, weight: .semibold)); Spacer(); Text("模拟回测").font(.system(size: 10)).foregroundStyle(Design.secondary) }
            HStack {
                evaluationMetric("80% 区间覆盖率", value: String(format: "%.1f%%", forecast.backtest.coverage*100))
                Spacer()
                evaluationMetric("中位绝对误差", value: String(format: "%.1f%%", forecast.backtest.medianError*100))
                Spacer()
                evaluationMetric("回测样本", value: "\(forecast.backtest.sampleCount)")
            }
            Text(forecast.backtest.description).font(.system(size: 10)).foregroundStyle(Design.secondary).lineSpacing(3)
            Divider()
            Button { showCost = true } label: {
                HStack { Image(systemName: "cpu"); Text("推理用量与成本估算"); Spacer(); Image(systemName: "chevron.right").font(.system(size: 9)) }
                    .font(.system(size: 11)).foregroundStyle(Design.secondary)
            }
        }.padding(18).card()
    }

    private func historyCard(_ snapshot: MarketSnapshot, _ forecast: Forecast) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("历史行情").font(.system(size: 18, weight: .semibold)); Spacer(); Text("近 60 个交易日").font(.system(size: 11)).foregroundStyle(Design.secondary) }
            ForecastChart(snapshot: snapshot, forecast: forecast, confidence: model.confidence, historicalOnly: true).frame(height: 230)
            legend("收盘价格 · CNY", color: Design.blue)
        }.padding(18).card()
    }
    private func marketDetails(_ asset: MarketAsset) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("行情概览").font(.system(size: 16, weight: .semibold))
            HStack { evaluationMetric("今开", value: asset.formatted(asset.open)); Spacer(); evaluationMetric("最高", value: asset.formatted(asset.high)); Spacer(); evaluationMetric("最低", value: asset.formatted(asset.low)) }
            HStack { evaluationMetric("昨收", value: asset.formatted(asset.previousClose)); Spacer(); evaluationMetric("成交额", value: asset.volume); Spacer(); evaluationMetric("交易币种", value: "CNY") }
        }.padding(18).card()
    }
    private var sourceFooter: some View {
        VStack(spacing: 8) {
            HStack(spacing: 5) { Image(systemName: "point.3.connected.trianglepath.dotted"); Text((model.snapshot?.marketSourceLabel ?? "行情加载中") + " · 预测模拟") }.font(.system(size: 10, weight: .medium))
            Text((model.snapshot?.sourceDescription ?? "") + "\n概率区间不代表收益保证，不构成投资建议。")
                .font(.system(size: 9)).multilineTextAlignment(.center).lineSpacing(4)
        }.foregroundStyle(Design.secondary).frame(maxWidth: .infinity).padding(.vertical, 12)
    }
    private var bottomNavigation: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Design.line).frame(height: 0.5)
            HStack(spacing: 0) {
                navItem("市场", icon: "square.grid.2x2") { bottomTab = "市场"; showAssets = true }
                navItem("自选", icon: "star") { bottomTab = "自选"; showAssets = true }
                navItem("预测", icon: "waveform.path") { bottomTab = "预测"; activeTab = "AI 预测" }
                Spacer(minLength: 10)
                Button { showDelivery = true } label: {
                    HStack(spacing: 7) { Image(systemName: "paperplane.fill").font(.system(size: 12)); Text("下发预测").font(.system(size: 13, weight: .semibold)) }
                        .foregroundStyle(Design.onAction).frame(width: 131, height: 43)
                        .background(Design.action, in: RoundedRectangle(cornerRadius: 11))
                }.disabled(model.forecast == nil || model.loading).opacity(model.loading ? 0.5 : 1)
            }.padding(.horizontal, 20).padding(.top, 11).padding(.bottom, 7)
        }.background(Design.surface)
    }
    private func navItem(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) { Image(systemName: icon).font(.system(size: 19, weight: .medium)); Text(title).font(.system(size: 9, weight: .medium)) }
                .foregroundStyle(bottomTab == title ? Design.orange : Design.secondary).frame(width: 57, height: 44)
        }
    }
    private var engineBadge: some View {
        HStack(spacing: 3) { Image(systemName: "waveform.path"); Text("RWKV") }
            .font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(Design.orange)
            .padding(.horizontal, 5).padding(.vertical, 4).background(Design.orangeSoft, in: RoundedRectangle(cornerRadius: 4))
    }
    private func legend(_ name: String, color: Color, dashed: Bool = false) -> some View {
        HStack(spacing: 4) {
            if dashed { HStack(spacing: 2) { Rectangle().fill(color).frame(width: 4, height: 1.5); Rectangle().fill(color).frame(width: 4, height: 1.5) } }
            else { Capsule().fill(color).frame(width: 10, height: 2) }
            Text(name).font(.system(size: 9)).foregroundStyle(Design.secondary)
        }
    }
    private func forecastMetric(_ title: String, value: String, detail: String, color: Color) -> some View {
        VStack(spacing: 6) { Text(title).font(.system(size: 10)).foregroundStyle(Design.secondary); Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).minimumScaleFactor(0.7).lineLimit(1); Text(detail).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(color) }.frame(maxWidth: .infinity)
    }
    private func evaluationMetric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title).font(.system(size: 10)).foregroundStyle(Design.secondary); Text(value).font(.system(size: 19, weight: .semibold, design: .rounded)) }
    }
    private func timestamp(_ value: String, format: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: value) else { return value }
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
    private func percent(_ price: Double, _ current: Double) -> String { String(format: "%+.2f%%", (price/current-1)*100) }
    private func showToast(_ value: String) {
        withAnimation { toast = value }
        Task { try? await Task.sleep(for: .seconds(2)); withAnimation { toast = nil } }
    }
    private var methodSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Label("让预测呈现不确定性", systemImage: "waveform.path").font(.title3.bold())
                    methodItem("区间如何阅读", "浅色区域表示所选 80% 或 95% 的预测区间；深色区域表示中间 50% 区间；虚线是中位走势。概率是模型对可能路径的估计。")
                    methodItem("为什么区间逐渐变宽", "预测越远，不确定性通常越高。区间由每个未来交易日的分位数构成，因此能呈现整段走势范围，而不只是最高价和最低价。")
                    methodItem("上涨概率", "表示期末价格高于当前价格的模拟概率，与区间覆盖水平是不同概念。")
                    methodItem("数据与模型", (model.snapshot?.sourceDescription ?? "") + "行情采用不复权日线，展示最近完整交易日；未来日期暂只跳过周末，未对齐交易所节假日。")
                    Link("查看 AKShare 数据文档 ↗", destination: URL(string: "https://akshare.akfamily.xyz/index.html")!).font(.subheadline).tint(Design.orange)
                }.padding(24)
            }.navigationTitle("关于走势预测").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showMethod = false }.tint(Design.orange) } }
        }.presentationDragIndicator(.visible)
    }
    private func methodItem(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title).font(.subheadline.bold()); Text(text).font(.subheadline).foregroundStyle(.secondary).lineSpacing(6) }
    }
}

extension View {
    func card() -> some View {
        background(Design.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).stroke(Design.line.opacity(0.6), lineWidth: 0.5) }
    }
}

#Preview { ContentView() }
