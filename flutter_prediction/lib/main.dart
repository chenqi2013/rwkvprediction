import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_request_log.dart';
import 'market_controller.dart';
import 'market_page.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final preferences = await SharedPreferences.getInstance();
  final requestLog = ApiRequestLog();
  await requestLog.initialize();
  runApp(
    PredictionApp(
      controller: MarketController(preferences, requestLog: requestLog),
    ),
  );
}

class PredictionApp extends StatelessWidget {
  const PredictionApp({super.key, required this.controller});
  final MarketController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, child) => MaterialApp(
      title: '知势 · RWKV',
      debugShowCheckedModeBanner: false,
      theme: marketTheme(false),
      darkTheme: marketTheme(true),
      themeMode: controller.dark ? ThemeMode.dark : ThemeMode.light,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      scrollBehavior: const MaterialScrollBehavior().copyWith(
        dragDevices: {
          PointerDeviceKind.touch,
          PointerDeviceKind.mouse,
          PointerDeviceKind.trackpad,
          PointerDeviceKind.stylus,
        },
      ),
      home: MarketPage(controller: controller),
    ),
  );
}
