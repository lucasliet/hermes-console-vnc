/// Host of the virtual HTTPS origin that serves the vendored noVNC page.
///
/// Android's WebViewAssetLoader answers this host from the app assets, so
/// the page is not cleartext and is not requested from the network.
const String screenAssetHost = 'appassets.androidplatform.net';

/// Method channel that installs the asset loader on the takeover WebView.
const String screenAssetChannelName = 'hermes/screen_assets';

/// `bridge.html` on [screenAssetHost] that opens [wsUrl], with overlay [copy].
Uri screenAssetPageUri(String wsUrl, {Map<String, String> copy = const {}}) {
  final query = <String, String>{'ws': wsUrl};
  for (final entry in copy.entries) {
    if (entry.key.isEmpty || entry.value.isEmpty) continue;
    query[entry.key] = entry.value;
  }
  return Uri(
    scheme: 'https',
    host: screenAssetHost,
    path: '/assets/novnc/bridge.html',
    queryParameters: query,
  );
}

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
