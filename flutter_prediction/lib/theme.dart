import 'package:flutter/material.dart';

class MarketColors {
  MarketColors(this.dark);
  final bool dark;
  factory MarketColors.of(BuildContext context) =>
      MarketColors(Theme.of(context).brightness == Brightness.dark);
  Color get canvas => Color(dark ? 0xFF101113 : 0xFFF3F4F5);
  Color get surface => Color(dark ? 0xFF191A1E : 0xFFFFFFFF);
  Color get selected => Color(dark ? 0xFF303136 : 0xFFFFFFFF);
  Color get ink => Color(dark ? 0xFFF0F0F2 : 0xFF202124);
  Color get secondary => Color(dark ? 0xFF909299 : 0xFF888B92);
  Color get body => Color(dark ? 0xFFC0C8D4 : 0xFF626975);
  Color get line => Color(dark ? 0xFF2B2C31 : 0xFFECEEF0);
  Color get orange => const Color(0xFFFF9300);
  Color get orangeSoft => Color(dark ? 0xFF332719 : 0xFFFFF4E5);
  Color get blue => Color(dark ? 0xFF89A6FF : 0xFF5776D7);
  Color get green => Color(dark ? 0xFF00BD83 : 0xFF009B6B);
  Color get red => Color(dark ? 0xFFFF5058 : 0xFFE83E4D);
  Color get action => orange;
  Color get onAction => const Color(0xFF181818);
}

ThemeData marketTheme(bool dark) {
  final palette = MarketColors(dark);
  final scheme = ColorScheme.fromSeed(
    seedColor: palette.orange,
    brightness: dark ? Brightness.dark : Brightness.light,
    surface: palette.surface,
  ).copyWith(primary: palette.orange, onSurface: palette.ink);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: palette.canvas,
    splashFactory: InkSparkle.splashFactory,
    dividerColor: palette.line,
    fontFamilyFallback: const [
      'PingFang SC',
      'Microsoft YaHei',
      'Noto Sans CJK SC',
    ],
    appBarTheme: AppBarTheme(
      backgroundColor: palette.surface,
      foregroundColor: palette.ink,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
    ),
    textTheme: Typography.material2021().black.apply(
      bodyColor: palette.ink,
      displayColor: palette.ink,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: palette.action,
        foregroundColor: palette.onAction,
        minimumSize: const Size(48, 46),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: palette.canvas,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.all(14),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: palette.surface,
      surfaceTintColor: Colors.transparent,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: palette.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
    ),
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 400),
    ),
  );
}

class MarketPanel extends StatelessWidget {
  const MarketPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
  });
  final Widget child;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) {
    final colors = MarketColors.of(context);
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: colors.line, width: .6),
      ),
      child: child,
    );
  }
}

class MarketBadge extends StatelessWidget {
  const MarketBadge(this.label, {super.key, this.icon});
  final String label;
  final IconData? icon;
  @override
  Widget build(BuildContext context) {
    final colors = MarketColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: colors.orangeSoft,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: colors.orange),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              color: colors.orange,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class PanelTitle extends StatelessWidget {
  const PanelTitle(this.title, {super.key, this.trailing});
  final String title;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(
          title,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
      ),
      ?trailing,
    ],
  );
}
