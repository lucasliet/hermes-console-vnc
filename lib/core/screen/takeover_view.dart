import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import 'screen_server.dart';

/// Whether the embedded page may follow [requestUrl].
///
/// Only `https` on the same host and port as [page] is allowed, so the
/// asset-loader page can be replaced with a fresh ticket and nothing else
/// can navigate away.
NavigationDecision screenNavigationDecision(Uri page, String requestUrl) {
  final uri = Uri.tryParse(requestUrl);
  if (uri == null || uri.userInfo.isNotEmpty) {
    return NavigationDecision.prevent;
  }
  if (uri.scheme != 'https') return NavigationDecision.prevent;
  if (uri.host.toLowerCase() != page.host.toLowerCase()) {
    return NavigationDecision.prevent;
  }
  if (uri.port != page.port) return NavigationDecision.prevent;
  return NavigationDecision.navigate;
}

/// Installs the on-device asset loader for [controller], when it is Android.
///
/// Tests and other platforms leave the WebView as the caller configured it.
/// The page is then loaded from `https://appassets.androidplatform.net`,
/// which the loader serves from the app bundle. The loader replaces the
/// WebView client, so it also enforces the navigation rule of
/// [screenNavigationDecision] and reports a failed asset through
/// [onLoadFailed].
Future<void> installScreenAssetHost(
  WebViewController controller, {
  VoidCallback? onLoadFailed,
}) async {
  if (defaultTargetPlatform != TargetPlatform.android) return;
  final platform = controller.platform;
  if (platform is! AndroidWebViewController) return;
  const channel = MethodChannel(screenAssetChannelName);
  channel.setMethodCallHandler((call) async {
    if (call.method == 'loadFailed') onLoadFailed?.call();
  });
  await channel.invokeMethod<void>('install', platform.webViewIdentifier);
}

/// Stops listening for asset failures from the on-device asset loader.
void releaseScreenAssetHost() {
  if (defaultTargetPlatform != TargetPlatform.android) return;
  const MethodChannel(screenAssetChannelName).setMethodCallHandler(null);
}

/// noVNC page served by the Android asset loader.
class TakeoverView extends StatefulWidget {
  /// Creates a view of [pageUri].
  const TakeoverView({
    required this.pageUri,
    required this.onBridgeMessage,
    this.onUnavailable,
    super.key,
  });

  /// `bridge.html` URL, including the display websocket.
  final Uri pageUri;

  /// Messages from the page (`lost`, `reconnect`, and the other status tokens).
  final ValueChanged<String> onBridgeMessage;

  /// Called when the asset host cannot be installed or the page cannot load.
  final VoidCallback? onUnavailable;

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

  @override
  void didUpdateWidget(TakeoverView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pageUri == widget.pageUri) return;
    unawaited(_controller.loadRequest(widget.pageUri));
  }

  Future<void> _open() async {
    try {
      final controller = _controller;
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.setBackgroundColor(const Color(0xFF000000));
      await controller.addJavaScriptChannel(
        'TakeoverChannel',
        onMessageReceived: (message) {
          if (!mounted) return;
          widget.onBridgeMessage(message.message);
        },
      );
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) =>
              screenNavigationDecision(widget.pageUri, request.url),
        ),
      );
      await _lockDown(controller);
      await installScreenAssetHost(
        controller,
        onLoadFailed: () {
          if (mounted) widget.onUnavailable?.call();
        },
      );
      if (!mounted) return;
      await controller.loadRequest(widget.pageUri);
    } catch (_) {
      if (mounted) widget.onUnavailable?.call();
    }
  }

  Future<void> _lockDown(WebViewController controller) async {
    final platform = controller.platform;
    if (platform is! AndroidWebViewController) return;
    await platform.setAllowFileAccess(false);
    await platform.setAllowContentAccess(false);
    await platform.setGeolocationEnabled(false);
    final socket = widget.pageUri.queryParameters['ws'] ?? '';
    await platform.setMixedContentMode(
      socket.startsWith('ws://')
          ? MixedContentMode.alwaysAllow
          : MixedContentMode.neverAllow,
    );
    await platform.setGeolocationPermissionsPromptCallbacks(
      onShowPrompt: (_) async =>
          const GeolocationPermissionsResponse(allow: false, retain: false),
    );
    await platform.setOnShowFileSelector((_) async => const <String>[]);
  }

  @override
  void dispose() {
    releaseScreenAssetHost();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => WebViewWidget(controller: _controller);
}
