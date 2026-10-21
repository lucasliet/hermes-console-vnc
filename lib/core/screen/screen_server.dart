import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

/// Asset key for a request path under the vendored noVNC tree, or null when
/// the path escapes that tree.
String? safeNovncAssetKey(String urlPath) {
  var rel = urlPath;
  if (rel.startsWith('/')) rel = rel.substring(1);
  if (rel.isEmpty || rel.endsWith('/')) {
    rel = rel.endsWith('/') ? '${rel}bridge.html' : 'bridge.html';
  }
  if (rel.contains('\\') || rel.contains('\u0000')) return null;
  final segments = rel.split('/');
  if (segments.any(
    (segment) => segment.isEmpty || segment == '.' || segment == '..',
  )) {
    return null;
  }
  return 'assets/novnc/$rel';
}

/// Loopback HTTP server for the noVNC page.
///
/// The page has to be a real origin so ES modules resolve and a cleartext
/// `ws://` display socket is not mixed content. It binds only to 127.0.0.1
/// and serves files under `assets/novnc/`.
class ScreenAssetServer {
  ScreenAssetServer._(this._server, this.baseUri);

  final HttpServer _server;

  /// Origin of this server, without a path.
  final Uri baseUri;

  /// Starts a server on an ephemeral loopback port.
  static Future<ScreenAssetServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final assetServer = ScreenAssetServer._(
      server,
      Uri.parse('http://127.0.0.1:${server.port}'),
    );
    server.listen(
      assetServer._handle,
      onError: (Object _) {},
      cancelOnError: false,
    );
    return assetServer;
  }

  /// `bridge.html` URL that opens [wsUrl], with optional overlay [copy].
  Uri pageUri(String wsUrl, {Map<String, String> copy = const {}}) {
    final query = <String, String>{'ws': wsUrl};
    for (final entry in copy.entries) {
      if (entry.key.isEmpty || entry.value.isEmpty) continue;
      query[entry.key] = entry.value;
    }
    return baseUri.replace(path: '/bridge.html', queryParameters: query);
  }

  /// Stops the server.
  Future<void> dispose() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.method != 'GET') {
        request.response.statusCode = HttpStatus.methodNotAllowed;
        await request.response.close();
        return;
      }
      final key = safeNovncAssetKey(request.uri.path);
      if (key == null) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final ByteData data;
      try {
        data = await rootBundle.load(key);
      } catch (_) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      request.response.headers.set(
        HttpHeaders.contentTypeHeader,
        _contentType(key),
      );
      request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      request.response.headers.set('x-content-type-options', 'nosniff');
      request.response.contentLength = bytes.length;
      request.response.add(bytes);
      await request.response.close();
    } catch (_) {
      await request.response.close();
    }
  }

  static String _contentType(String path) {
    if (path.endsWith('.html')) return 'text/html; charset=utf-8';
    if (path.endsWith('.js') || path.endsWith('.mjs')) {
      return 'application/javascript; charset=utf-8';
    }
    if (path.endsWith('.css')) return 'text/css; charset=utf-8';
    if (path.endsWith('.json')) return 'application/json; charset=utf-8';
    if (path.endsWith('.svg')) return 'image/svg+xml';
    if (path.endsWith('.png')) return 'image/png';
    if (path.endsWith('.txt')) return 'text/plain; charset=utf-8';
    return 'application/octet-stream';
  }
}
