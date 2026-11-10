import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final apple = [OS.macOS, OS.iOS].contains(input.config.code.targetOS);
    await CBuilder.library(
      name: 'rwkv_minute',
      assetName: 'rwkv_native.dart',
      sources: ['native/rwkv_minute.cpp'],
      language: Language.cpp,
      std: 'c++17',
      buildMode: BuildMode.release,
      flags: [
        if (apple) ...['-framework', 'Accelerate'],
        if (input.config.code.targetOS != OS.windows) '-ffp-contract=off',
      ],
    ).run(input: input, output: output);
  });
}
