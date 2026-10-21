import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/screen/screen_controller.dart';
import 'package:hermes_android/core/screen/screen_server.dart';
import 'package:hermes_android/core/screen/takeover_view.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('peek status treats a missing installed flag as present', () {
    final state = DisplayState.fromJson({
      'running': false,
      'status': 'running',
      'lease_holder': 'human',
    });
    expect(state.running, isTrue);
    expect(state.installed, isTrue);
    expect(state.leaseHolder, 'human');
  });

  test('runtime status requires explicit booleans and a lease object', () {
    final runtime = DisplayRuntime.fromJson({
      'supported': true,
      'running': true,
      'blocker': 'memory',
      'geometry': '1280x800',
      'lease': {'holder': 'agent', 'epoch': 4, 'since': 1, 'reason': 'boot'},
    });
    expect(runtime.supported, isTrue);
    expect(runtime.installed, isFalse);
    expect(runtime.running, isTrue);
    expect(runtime.blocker, 'memory');
    expect(runtime.lease.holder, 'agent');
    expect(runtime.lease.epoch, 4);
    expect(runtime.lease.heldByHuman, isFalse);
  });

  test('thumbnail reads a data url and the human suppression flag', () async {
    final controller = _controller((method, params) async {
      expect(method, 'display.thumbnail');
      expect(params, {'profile': 'default'});
      return {
        'data_url': 'data:image/jpeg;base64,YQ==',
        'suppressed': 'human_has_control',
      };
    });
    final frame = await controller.thumbnail(profile: 'default');
    expect(frame.dataUrl, contains('base64'));
    expect(frame.suppressedByHuman, isTrue);
  });

  test('observe requires a ticket and viewer id', () async {
    final controller = _controller(
      (method, params) async => {'path': '/api/display/ws'},
    );
    await expectLater(
      controller.observe(),
      throwsA(
        isA<ScreenControllerException>().having(
          (error) => error.kind,
          'kind',
          ScreenFailureKind.invalidResponse,
        ),
      ),
    );
  });

  test('observe keeps the gateway path and runtime', () async {
    final calls = <String>[];
    final controller = _controller((method, params) async {
      calls.add(method);
      return {
        'ticket': 'ticket-1',
        'viewer_id': 'viewer-1',
        'path': '/api/display/ws',
        'supported': true,
        'installed': true,
        'running': true,
        'lease': {'holder': 'agent', 'epoch': 1, 'since': 1},
      };
    });
    final session = await controller.observe(profile: 'work');
    expect(calls, ['display.observe']);
    expect(session.ticket, 'ticket-1');
    expect(session.viewerId, 'viewer-1');
    expect(session.path, '/api/display/ws');
    expect(session.runtime.running, isTrue);
  });

  test('acquire and release send the viewer id and profile', () async {
    final seen = <Map<String, dynamic>>[];
    final controller = _controller((method, params) async {
      seen.add({'method': method, ...params});
      return {
        'lease': {
          'holder': 'human',
          'viewer_hash': 'hash-us',
          'epoch': 2,
          'since': 9,
        },
      };
    });
    final acquired = await controller.acquire('viewer-1', profile: 'work');
    final released = await controller.release('viewer-1', profile: 'work');
    expect(acquired.heldByHuman, isTrue);
    expect(acquired.viewerHash, 'hash-us');
    expect(released.epoch, 2);
    expect(seen, [
      {
        'method': 'display.lease.acquire',
        'profile': 'work',
        'viewer_id': 'viewer-1',
        'reason': 'hermes-console',
      },
      {
        'method': 'display.lease.release',
        'profile': 'work',
        'viewer_id': 'viewer-1',
      },
    ]);
  });

  test('display websocket uses the dashboard host and only the ticket', () {
    final controller = _controller(
      (method, params) async => {},
      base: Uri.parse('https://hermes.example/prefix'),
    );
    final uri = controller.displayWsUri('/api/display/ws', 'ticket-1');
    expect(uri.scheme, 'wss');
    expect(uri.host, 'hermes.example');
    expect(uri.path, '/prefix/api/display/ws');
    expect(uri.queryParameters, {'display_ticket': 'ticket-1'});
  });

  test('display websocket does not double a prefixed path', () {
    final controller = _controller(
      (method, params) async => {},
      base: Uri.parse('http://127.0.0.1:9119/hermes'),
    );
    final uri = controller.displayWsUri('/hermes/api/display/ws', 'ticket-1');
    expect(uri.scheme, 'ws');
    expect(uri.path, '/hermes/api/display/ws');
  });

  test('display websocket rejects an empty ticket and a non-http base', () {
    final controller = _controller((method, params) async => {});
    expect(
      () => controller.displayWsUri('/api/display/ws', ''),
      throwsA(isA<ScreenControllerException>()),
    );
    final odd = _controller(
      (method, params) async => {},
      base: Uri.parse('ftp://127.0.0.1/hermes'),
    );
    expect(
      () => odd.displayWsUri('/api/display/ws', 'ticket-1'),
      throwsA(
        isA<ScreenControllerException>().having(
          (error) => error.kind,
          'kind',
          ScreenFailureKind.unavailable,
        ),
      ),
    );
  });

  test('lease events and takeover detection follow the holder hash', () async {
    final payloads = Stream<Map<String, dynamic>>.fromIterable([
      {
        'profile_key': 'default',
        'lease': {
          'holder': 'human',
          'viewer_hash': 'other',
          'epoch': 3,
          'since': 1,
        },
      },
    ]);
    final controller = ScreenController(
      rpc: (method, params) async => {},
      leasePayloads: payloads,
      dashboardBase: () => Uri.parse('http://127.0.0.1:9119'),
    );
    final lease = await controller.watchLease().first;
    expect(lease.viewerHash, 'other');
    expect(displayLeaseTakenOver(lease, ourViewerHash: 'hash-us'), isTrue);
    expect(displayLeaseTakenOver(lease, ourViewerHash: 'other'), isFalse);
    expect(
      displayLeaseTakenOver(
        const DisplayLeaseInfo(
          holder: 'agent',
          viewerHash: '',
          epoch: 1,
          reason: '',
        ),
        ourViewerHash: 'hash-us',
      ),
      isTrue,
    );
    expect(
      displayLeaseTakenOver(
        const DisplayLeaseInfo(
          holder: 'human',
          viewerHash: '',
          epoch: 1,
          reason: '',
        ),
        ourViewerHash: 'hash-us',
      ),
      isFalse,
    );
  });

  test('display RPC allowlist keeps control off read-only connections', () {
    for (final method in ['display.status', 'display.thumbnail']) {
      expect(
        TuiGatewayClient.displayRpcAllowed(method, readOnly: true),
        isTrue,
      );
      expect(
        TuiGatewayClient.displayRpcAllowed(method, readOnly: false),
        isTrue,
      );
    }
    for (final method in [
      'display.start',
      'display.observe',
      'display.lease.acquire',
      'display.lease.release',
    ]) {
      expect(
        TuiGatewayClient.displayRpcAllowed(method, readOnly: true),
        isFalse,
      );
      expect(
        TuiGatewayClient.displayRpcAllowed(method, readOnly: false),
        isTrue,
      );
    }
    expect(
      TuiGatewayClient.displayRpcAllowed('session.list', readOnly: false),
      isFalse,
    );
  });

  test('rejected display calls do not dial the gateway', () async {
    final client = TuiGatewayClient(
      SavedConnection(
        id: 'screen-ro',
        label: 'Read only',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'test-only',
        readOnly: true,
        dashboardUrl: 'http://127.0.0.1:9',
      ),
    );
    addTearDown(client.close);
    await expectLater(
      client.displayRequest('display.observe', const {}),
      throwsA(isA<TuiGatewayRpcError>()),
    );
    await expectLater(
      client.displayRequest('display.status', const {'profile': 'Not A Name'}),
      throwsA(isA<TuiGatewayRpcError>()),
    );
    expect(client.isConnected, isFalse);
  });

  test('noVNC asset keys stay inside the vendored tree', () {
    expect(safeNovncAssetKey('/bridge.html'), 'assets/novnc/bridge.html');
    expect(safeNovncAssetKey('/core/rfb.js'), 'assets/novnc/core/rfb.js');
    expect(safeNovncAssetKey('/'), 'assets/novnc/bridge.html');
    expect(safeNovncAssetKey('/../pubspec.yaml'), isNull);
    expect(safeNovncAssetKey('/core/../../pubspec.yaml'), isNull);
    expect(safeNovncAssetKey('/core/./rfb.js'), isNull);
    expect(safeNovncAssetKey('/core\\rfb.js'), isNull);
  });

  test('loopback page can reload and cannot leave its origin', () {
    final page = Uri.parse('http://127.0.0.1:4312/bridge.html?ws=1');
    expect(
      screenNavigationDecision(page, 'http://127.0.0.1:4312/bridge.html'),
      NavigationDecision.navigate,
    );
    expect(
      screenNavigationDecision(page, 'https://evil.test/bridge.html'),
      NavigationDecision.prevent,
    );
    expect(
      screenNavigationDecision(page, 'http://127.0.0.1/bridge.html'),
      NavigationDecision.prevent,
    );
    expect(
      screenNavigationDecision(page, 'javascript:alert(1)'),
      NavigationDecision.prevent,
    );
    expect(
      screenNavigationDecision(page, 'http://user:pass@127.0.0.1:4312/x'),
      NavigationDecision.prevent,
    );
  });

  test('asset server serves the bridge and refuses escape', () async {
    final server = await ScreenAssetServer.start();
    addTearDown(server.dispose);

    final bridge = await _get(server.baseUri.replace(path: '/bridge.html'));
    expect(bridge.status, 200);
    expect(bridge.body, contains('import RFB'));
    expect(bridge.contentType, contains('text/html'));

    final core = await _get(server.baseUri.replace(path: '/core/rfb.js'));
    expect(core.status, 200);
    expect(core.body, contains('MPL 2.0'));

    final missing = await _get(server.baseUri.replace(path: '/nope.js'));
    expect(missing.status, 404);

    final posted = await _send(
      server.baseUri.port,
      'POST /bridge.html HTTP/1.1',
    );
    expect(posted, contains('405'));

    final escaped = await _send(
      server.baseUri.port,
      'GET /core/%2e%2e/%2e%2e/pubspec.yaml HTTP/1.1',
    );
    expect(escaped, contains('404'));
    expect(escaped, isNot(contains('name: hermes_android')));
  });
}

ScreenController _controller(DisplayRpc rpc, {Uri? base}) => ScreenController(
  rpc: rpc,
  leasePayloads: const Stream.empty(),
  dashboardBase: () => base ?? Uri.parse('http://127.0.0.1:9119'),
);

Future<({int status, String body, String contentType})> _get(Uri uri) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, uri.port);
  socket.write(
    'GET ${uri.path} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n',
  );
  await socket.flush();
  final raw = await utf8.decodeStream(socket);
  final headerEnd = raw.indexOf('\r\n\r\n');
  final header = headerEnd < 0 ? raw : raw.substring(0, headerEnd);
  final body = headerEnd < 0 ? '' : raw.substring(headerEnd + 4);
  final status = int.parse(header.split(' ')[1]);
  var contentType = '';
  for (final line in header.split('\r\n').skip(1)) {
    final colon = line.indexOf(':');
    if (colon < 0) continue;
    if (line.substring(0, colon).toLowerCase() == 'content-type') {
      contentType = line.substring(colon + 1).trim();
    }
  }
  return (status: status, body: body, contentType: contentType);
}

Future<String> _send(int port, String requestLine) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
  socket.write('$requestLine\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n');
  await socket.flush();
  final body = await utf8.decodeStream(socket);
  return body;
}
