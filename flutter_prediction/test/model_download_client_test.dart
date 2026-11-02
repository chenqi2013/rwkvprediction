import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rwkv_prediction/model_download_client.dart';

class _RealHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('rwkv_prediction/system_proxy');

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('single Windows proxy covers HTTPS and redirected storage hosts', () {
    const proxy = WindowsDownloadProxy('127.0.0.1:7890', '');
    for (final url in [
      'https://huggingface.co/model/resolve/main/model.gguf',
      'https://storage.example.net/model.gguf',
      'http://example.net/file',
    ]) {
      expect(proxy.findProxy(Uri.parse(url)), 'PROXY 127.0.0.1:7890');
    }
  });

  test('per-scheme Windows entries choose the HTTPS proxy', () {
    const proxy = WindowsDownloadProxy(
      'http=127.0.0.1:8080; https=127.0.0.1:7890; socks=127.0.0.1:1080',
      '',
    );
    expect(
      proxy.findProxy(Uri.parse('https://huggingface.co/model')),
      'PROXY 127.0.0.1:7890',
    );
    expect(
      proxy.findProxy(Uri.parse('http://example.net')),
      'PROXY 127.0.0.1:8080',
    );
    expect(proxy.findProxy(Uri.parse('ftp://example.net')), isNull);
  });

  test('Windows bypass rules match complete hosts and optional ports', () {
    const proxy = WindowsDownloadProxy(
      'http://127.0.0.1:7890',
      '<local>;*.internal;exact.example;port.example:8080',
    );
    for (final url in [
      'http://localhost:8787',
      'http://127.0.0.1:8787',
      'http://[::1]:8787',
      'http://intranet',
      'https://api.internal',
      'https://EXACT.EXAMPLE',
      'http://port.example:8080',
    ]) {
      expect(proxy.findProxy(Uri.parse(url)), 'DIRECT', reason: url);
    }
    for (final url in [
      'https://exact.example.attacker.net',
      'https://notinternal.example',
      'http://port.example:8081',
    ]) {
      expect(
        proxy.findProxy(Uri.parse(url)),
        'PROXY 127.0.0.1:7890',
        reason: url,
      );
    }
  });

  test('disabled or unsupported proxies leave environment handling intact', () {
    for (final server in [
      '',
      'socks=127.0.0.1:1080',
      'socks5://127.0.0.1:1080',
      'http://127.0.0.1:7890/path',
      'http://user:password@127.0.0.1:7890',
      '127.0.0.1:99999',
    ]) {
      expect(
        WindowsDownloadProxy(
          server,
          '',
        ).findProxy(Uri.parse('https://huggingface.co/model')),
        isNull,
        reason: server,
      );
    }
  });

  test(
    'download client uses system proxy across a cross-host redirect',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => proxy.close(force: true));
      final requestedHosts = <String>[];
      proxy.listen((request) async {
        requestedHosts.add(request.uri.host);
        if (requestedHosts.length == 1) {
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(
            HttpHeaders.locationHeader,
            'http://model-storage.invalid/model.gguf',
          );
        } else {
          request.response.add([0x47, 0x47, 0x55, 0x46]);
        }
        await request.response.close();
      });
      var lookups = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'getProxySettings');
            lookups++;
            return {'server': '127.0.0.1:${proxy.port}', 'bypass': '<local>'};
          });
      final client = await HttpOverrides.runWithHttpOverrides(
        createModelDownloadClient,
        _RealHttpOverrides(),
      );
      addTearDown(client.close);
      final response = await client
          .get(Uri.parse('http://huggingface.invalid/model.gguf'))
          .timeout(const Duration(seconds: 5));
      expect(response.statusCode, 200);
      expect(response.body, 'GGUF');
      expect(requestedHosts, ['huggingface.invalid', 'model-storage.invalid']);
      expect(lookups, 1);

      final retryClient = await createModelDownloadClient();
      addTearDown(retryClient.close);
      expect(lookups, 2);
    },
  );
}
