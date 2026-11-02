import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/io_client.dart';

const _proxyChannel = MethodChannel('rwkv_prediction/system_proxy');

Future<IOClient> createModelDownloadClient() async {
  WindowsDownloadProxy? proxy;
  if (defaultTargetPlatform == TargetPlatform.windows) {
    final settings = await _proxyChannel.invokeMapMethod<String, String>(
      'getProxySettings',
    );
    if (settings != null) {
      proxy = WindowsDownloadProxy(
        settings['server'] ?? '',
        settings['bypass'] ?? '',
      );
    }
  }
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20)
    ..findProxy = (uri) =>
        proxy?.findProxy(uri) ?? HttpClient.findProxyFromEnvironment(uri);
  return IOClient(client);
}

class WindowsDownloadProxy {
  const WindowsDownloadProxy(this.server, this.bypass);

  final String server;
  final String bypass;

  String? findProxy(Uri uri) {
    final host = uri.host.toLowerCase();
    if (host == 'localhost' || host == '127.0.0.1' || host == '::1') {
      return 'DIRECT';
    }
    for (final entry in bypass.toLowerCase().split(RegExp(r'[;,\s]+'))) {
      if (entry.isEmpty) continue;
      if (entry == '<local>') {
        if (!host.contains('.') && !host.contains(':')) return 'DIRECT';
        continue;
      }
      final pattern = RegExp.escape(
        entry,
      ).replaceAll(r'\*', '.*').replaceAll(r'\?', '.');
      final target = entry.contains(':') ? '$host:${uri.port}' : host;
      if (RegExp('^$pattern\$').hasMatch(target)) return 'DIRECT';
    }

    String? address;
    for (final entry in server.split(';')) {
      final separator = entry.indexOf('=');
      if (separator < 0) {
        if (entry.trim().isNotEmpty) address = entry.trim();
      } else if (entry.substring(0, separator).trim().toLowerCase() ==
          uri.scheme.toLowerCase()) {
        address = entry.substring(separator + 1).trim();
        break;
      }
    }
    if (address == null || address.isEmpty) return null;
    final endpoint = Uri.tryParse(
      address.contains('://') ? address : 'http://$address',
    );
    if (endpoint == null ||
        endpoint.scheme != 'http' ||
        endpoint.host.isEmpty ||
        endpoint.userInfo.isNotEmpty ||
        (endpoint.path.isNotEmpty && endpoint.path != '/') ||
        endpoint.hasQuery ||
        endpoint.hasFragment ||
        endpoint.port <= 0 ||
        endpoint.port > 65535) {
      return null;
    }
    final proxyHost = endpoint.host.contains(':')
        ? '[${endpoint.host}]'
        : endpoint.host;
    return 'PROXY $proxyHost:${endpoint.port}';
  }
}
