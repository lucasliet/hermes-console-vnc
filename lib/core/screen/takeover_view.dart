import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// Whether the embedded page may follow [requestUrl].
///
/// Only `http` and `https` on the same host and port as [page] are allowed,
/// so the bridge can reload itself and nothing else can navigate away.
NavigationDecision screenNavigationDecision(Uri page, String requestUrl) {
  final uri = Uri.tryParse(requestUrl);
  if (uri == null || uri.userInfo.isNotEmpty) return NavigationDecision.prevent;
  final web = uri.scheme == 'http' || uri.scheme == 'https';
  if (!web || uri.host.toLowerCase() != page.host.toLowerCase()) {
    return NavigationDecision.prevent;
  }
  if (uri.port != page.port) return NavigationDecision.prevent;
  return NavigationDecision.navigate;
}

/// noVNC page hosted by the loopback asset server.
class TakeoverView extends StatefulWidget {
  /// Creates a view of [pageUri].
  const TakeoverView({required this.pageUri, super.key});

  /// `bridge.html` URL, including the display websocket.
  final Uri pageUri;

  @override
  State<TakeoverView> createState() => _TakeoverViewState();
}

class _TakeoverViewState extends State<TakeoverView> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController(
      onPermissionRequest: (request) {
        unawaited(request.deny());
      },
    );
    unawaited(_open());
  }

  Future<void> _open() async {
    final controller = _controller;
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await controller.setBackgroundColor(const Color(0xFF000000));
    await controller.setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: (request) =>
            screenNavigationDecision(widget.pageUri, request.url),
      ),
    );
    await _lockDown(controller);
    if (!mounted) return;
    await controller.loadRequest(widget.pageUri);
  }

  Future<void> _lockDown(WebViewController controller) async {
    final platform = controller.platform;
    if (platform is! AndroidWebViewController) return;
    await platform.setAllowFileAccess(false);
    await platform.setAllowContentAccess(false);
    await platform.setGeolocationEnabled(false);
    await platform.setMixedContentMode(MixedContentMode.neverAllow);
    await platform.setGeolocationPermissionsPromptCallbacks(
      onShowPrompt: (_) async =>
          const GeolocationPermissionsResponse(allow: false, retain: false),
    );
    await platform.setOnShowFileSelector((_) async => const <String>[]);
  }

  @override
  Widget build(BuildContext context) => WebViewWidget(controller: _controller);
}
