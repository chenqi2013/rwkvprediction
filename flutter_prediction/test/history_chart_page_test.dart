import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:rwkv_prediction/history_chart.dart';
import 'package:rwkv_prediction/history_chart_page.dart';
import 'package:rwkv_prediction/main.dart';
import 'package:rwkv_prediction/market_controller.dart';
import 'package:rwkv_prediction/market_service.dart';
import 'package:rwkv_prediction/theme.dart';

void main() {
  for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
    testWidgets('desktop history expands, resizes and exits on $platform', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final service = DemoMarketService();
      await tester.runAsync(service.assets);
      final controller = MarketController(preferences, service: service);
      await tester.pumpWidget(PredictionApp(controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.candlestick_chart_outlined));
      await tester.pumpAndSettle();
      final snapshot = controller.snapshot!;
      final button = find.byTooltip('全屏查看');
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      final chart = find.descendant(
        of: find.byType(HistoryChartPage),
        matching: find.byType(HistoryChart),
      );
      expect(tester.widget<HistoryChart>(chart).snapshot, same(snapshot));
      expect(tester.getSize(chart).width, greaterThan(1400));
      expect(tester.getSize(chart).height, greaterThan(800));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(chart));
      await tester.pump();
      expect(find.textContaining(' · 历史'), findsWidgets);
      await mouse.removePointer();
      tester.view.physicalSize = const Size(600, 1000);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<RotatedBox>(find.byKey(const ValueKey('landscape-history')))
            .quarterTurns,
        0,
      );
      expect(tester.getSize(chart).width, lessThan(600));
      expect(tester.getSize(chart).height, greaterThan(800));
      expect(tester.takeException(), isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(HistoryChartPage), findsNothing);
      expect(controller.snapshot, same(snapshot));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('退出全屏查看（Esc）'));
      await tester.pumpAndSettle();
      expect(find.byType(HistoryChartPage), findsNothing);
      expect(find.byTooltip('全屏查看'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      debugDefaultTargetPlatformOverride = null;
    });
  }

  for (final size in [const Size(390, 844), const Size(414, 896)]) {
    testWidgets(
      'history opens sideways, supports inspection and returns at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final service = DemoMarketService();
        await tester.runAsync(service.assets);
        final controller = MarketController(preferences, service: service);
        await tester.pumpWidget(PredictionApp(controller: controller));
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.candlestick_chart_outlined));
        await tester.pumpAndSettle();
        final snapshot = controller.snapshot!;
        final button = find.byTooltip('横屏查看');
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(find.byType(HistoryChartPage), findsOneWidget);
        final rotated = find.byKey(const ValueKey('landscape-history'));
        expect(tester.widget<RotatedBox>(rotated).quarterTurns, 1);
        final chart = find.descendant(
          of: find.byType(HistoryChartPage),
          matching: find.byType(HistoryChart),
        );
        expect(tester.widget<HistoryChart>(chart).snapshot, same(snapshot));
        expect(
          tester.getSize(chart).width,
          greaterThan(tester.getSize(chart).height),
        );
        final chartBox = tester.renderObject<RenderBox>(chart);
        final start = chartBox.localToGlobal(const Offset(120, 80));
        final end = chartBox.localToGlobal(const Offset(240, 80));
        final gesture = await tester.startGesture(start);
        await tester.pump(const Duration(milliseconds: 150));
        await gesture.moveTo(end);
        await tester.pump();
        expect(find.textContaining(' · 历史'), findsWidgets);
        await gesture.up();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        tester.view.physicalSize = Size(size.height, size.width);
        await tester.pumpAndSettle();
        expect(tester.widget<RotatedBox>(rotated).quarterTurns, 0);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('退出横屏'));
        await tester.pumpAndSettle();
        expect(find.byType(HistoryChartPage), findsNothing);
        expect(controller.snapshot, same(snapshot));
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.pumpAndSettle();
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byType(HistoryChartPage), findsNothing);
        expect(find.byTooltip('横屏查看'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      },
    );
  }

  testWidgets('compact sideways chart respects safe areas and larger text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final service = DemoMarketService();
    final snapshot = await tester.runAsync(() => service.snapshot('510300'));
    await tester.pumpWidget(
      MaterialApp(
        theme: marketTheme(false),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 568),
            padding: EdgeInsets.only(top: 44, bottom: 34),
            textScaler: TextScaler.linear(1.5),
          ),
          child: HistoryChartPage(snapshot: snapshot!),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final chartSize = tester.getSize(find.byType(HistoryChart));
    expect(chartSize.width, greaterThan(chartSize.height));
    expect(chartSize.height, greaterThan(150));
    expect(find.byTooltip('退出横屏'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
