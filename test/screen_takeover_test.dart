import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screen/screen_controller.dart';
import 'package:hermes_android/core/screens/screen_peek_screen.dart';
import 'package:hermes_android/core/screens/takeover_screen.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'support/fake_webview_platform.dart';

const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

void main() {
  late FakeWebViewPlatform webPlatform;

  setUp(() {
    webPlatform = FakeWebViewPlatform();
    WebViewPlatform.instance = webPlatform;
  });

  testWidgets('el vistazo muestra el fotograma y ofrece tomar el control', (
    tester,
  ) async {
    final calls = <String>[];
    final controller = _controller((method, params) async {
      calls.add(method);
      if (method == 'display.thumbnail') {
        return {'data_url': 'data:image/png;base64,$_png', 'suppressed': null};
      }
      return _runtime();
    });
    await _pump(
      tester,
      ScreenPeekScreen(controller: controller, profile: 'work'),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Pantalla del bot'), findsOneWidget);
    expect(find.text('Asumir el control'), findsOneWidget);
    expect(find.text('Se actualiza cada 4 s'), findsOneWidget);
    expect(calls, containsAll(['display.status', 'display.thumbnail']));
  });

  testWidgets('un vistazo suprimido avisa y solo lectura no toma el control', (
    tester,
  ) async {
    final controller = _controller((method, params) async {
      if (method == 'display.thumbnail') {
        return {'data_url': '', 'suppressed': 'human_has_control'};
      }
      return _runtime();
    });
    await _pump(
      tester,
      ScreenPeekScreen(controller: controller, readOnly: true),
    );
    await tester.pump();
    await tester.pump();

    expect(
      find.text(
        'Un humano controla la pantalla. Los fotogramas están en pausa.',
      ),
      findsOneWidget,
    );
    expect(
      find.text('Conexión de solo lectura. No se puede tomar el control.'),
      findsOneWidget,
    );
    expect(find.text('Asumir el control'), findsNothing);
  });

  testWidgets('el vistazo distingue parada, no instalada y method not found', (
    tester,
  ) async {
    await _pump(
      tester,
      ScreenPeekScreen(
        key: const ValueKey('stopped'),
        controller: _controller(
          (method, params) async => _runtime(running: false, installed: true),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('El ordenador del bot está parado.'), findsOneWidget);
    expect(find.text('Encender el ordenador del bot'), findsOneWidget);

    await _pump(
      tester,
      ScreenPeekScreen(
        key: const ValueKey('missing'),
        controller: _controller(
          (method, params) async => _runtime(installed: false),
        ),
      ),
    );
    await tester.pump();
    expect(
      find.text('La pantalla no está instalada en esta instancia.'),
      findsOneWidget,
    );

    await _pump(
      tester,
      ScreenPeekScreen(
        key: const ValueKey('unlisted'),
        controller: _controller(
          (method, params) async => throw const TuiGatewayRpcError(
            'display.status',
            'missing',
            code: -32601,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(
      find.text('La pantalla no está instalada en esta instancia.'),
      findsOneWidget,
    );
  });

  testWidgets('encender el ordenador del bot retoma el vistazo', (
    tester,
  ) async {
    var started = false;
    final controller = _controller((method, params) async {
      if (method == 'display.start') {
        started = true;
        return _runtime();
      }
      if (method == 'display.thumbnail') {
        return {'data_url': 'data:image/png;base64,$_png'};
      }
      return _runtime(running: started);
    });
    await _pump(tester, ScreenPeekScreen(controller: controller));
    await tester.pump();
    await tester.tap(find.text('Encender el ordenador del bot'));
    await tester.pump();
    await tester.pump();
    expect(started, isTrue);
    expect(find.text('Asumir el control'), findsOneWidget);
  });

  testWidgets('el vistazo vuelve a preguntar al cumplirse el intervalo', (
    tester,
  ) async {
    var polls = 0;
    final controller = _controller((method, params) async {
      if (method == 'display.status') polls += 1;
      return _runtime(running: false);
    });
    await _pump(tester, ScreenPeekScreen(controller: controller));
    await tester.pump();
    final first = polls;
    expect(first, greaterThan(0));
    await tester.pump(screenPeekPollInterval);
    await tester.pump();
    expect(polls, greaterThan(first));
  });

  testWidgets('tomar el control abre noVNC y devolver suelta el lease', (
    tester,
  ) async {
    final calls = <String>[];
    final leases = StreamController<Map<String, dynamic>>.broadcast();
    addTearDown(leases.close);
    final controller = _controller((method, params) async {
      calls.add(method);
      if (method == 'display.observe') {
        return {
          ..._runtime(),
          'ticket': 'ticket-1',
          'viewer_id': 'viewer-1',
          'path': '/api/display/ws',
        };
      }
      if (method == 'display.lease.acquire') {
        return {
          'lease': {
            'holder': 'human',
            'viewer_hash': 'hash-us',
            'epoch': 2,
            'since': 1,
          },
        };
      }
      return _runtime();
    }, leases: leases.stream);

    await _pump(
      tester,
      TakeoverScreen(controller: controller, profile: 'work'),
    );
    await tester.pump();
    await tester.pump();

    expect(
      find.text('Tienes el control. Toca, arrastra y escribe con normalidad.'),
      findsOneWidget,
    );
    expect(calls, [
      'display.status',
      'display.observe',
      'display.lease.acquire',
    ]);
    expect(webPlatform.controllers, isNotEmpty);
    final loaded = webPlatform.last.loadedRequests.single;
    expect(loaded.path, '/bridge.html');
    expect(loaded.queryParameters['ws'], contains('display_ticket=ticket-1'));
    expect(loaded.queryParameters['connecting'], 'Conectando…');

    leases.add({
      'lease': {'holder': 'agent', 'epoch': 3, 'since': 2},
    });
    await tester.pump();
    expect(find.text('Otro cliente asumió el control.'), findsOneWidget);

    await tester.tap(find.text('Devolver'));
    await tester.pump();
    expect(calls.where((method) => method == 'display.lease.release'), [
      'display.lease.release',
    ]);
  });

  testWidgets('una pantalla parada se inicia y un bloqueo no ofrece el botón', (
    tester,
  ) async {
    var started = false;
    final controller = _controller((method, params) async {
      if (method == 'display.start') {
        started = true;
        return _runtime();
      }
      if (method == 'display.observe') {
        return {
          ..._runtime(),
          'ticket': 'ticket-1',
          'viewer_id': 'viewer-1',
          'path': '/api/display/ws',
        };
      }
      if (method == 'display.lease.acquire') {
        return {
          'lease': {
            'holder': 'human',
            'viewer_hash': 'hash-us',
            'epoch': 1,
            'since': 1,
          },
        };
      }
      return _runtime(running: started, blocker: started ? '' : '');
    });
    await _pump(
      tester,
      TakeoverScreen(key: const ValueKey('start'), controller: controller),
    );
    await tester.pump();
    expect(find.text('Iniciar pantalla'), findsOneWidget);
    await tester.tap(find.text('Iniciar pantalla'));
    await tester.pump();
    await tester.pump();
    expect(started, isTrue);
    expect(
      find.text('Tienes el control. Toca, arrastra y escribe con normalidad.'),
      findsOneWidget,
    );

    await _pump(
      tester,
      TakeoverScreen(
        key: const ValueKey('blocked'),
        controller: _controller(
          (method, params) async => _runtime(running: false, blocker: 'memory'),
        ),
      ),
    );
    await tester.pump();
    expect(
      find.text('La pantalla está bloqueada y no se puede iniciar.'),
      findsOneWidget,
    );
    expect(find.text('Iniciar pantalla'), findsNothing);
  });

  testWidgets('sin display y en solo lectura no se abre el websocket', (
    tester,
  ) async {
    await _pump(
      tester,
      TakeoverScreen(
        key: const ValueKey('unsupported'),
        controller: _controller(
          (method, params) async =>
              _runtime(supported: false, installed: false),
        ),
      ),
    );
    await tester.pump();
    expect(
      find.text(
        'La pantalla no está instalada en esta instancia. Instálala desde Hermes Desktop.',
      ),
      findsOneWidget,
    );
    expect(webPlatform.controllers, isEmpty);

    await _pump(
      tester,
      TakeoverScreen(
        key: const ValueKey('readonly'),
        controller: _controller((method, params) async => _runtime()),
        readOnly: true,
      ),
    );
    await tester.pump();
    expect(
      find.text('Conexión de solo lectura. No se puede tomar el control.'),
      findsOneWidget,
    );
    expect(webPlatform.controllers, isEmpty);
  });
}

ScreenController _controller(
  DisplayRpc rpc, {
  Stream<Map<String, dynamic>>? leases,
}) => ScreenController(
  rpc: rpc,
  leasePayloads: leases ?? const Stream.empty(),
  dashboardBase: () => Uri.parse('http://127.0.0.1:9119'),
);

Map<String, dynamic> _runtime({
  bool supported = true,
  bool installed = true,
  bool running = true,
  String blocker = '',
}) => {
  'profile': 'default',
  'supported': supported,
  'installed': installed,
  'missing': <String>[],
  'running': running,
  'geometry': '1280x800',
  'blocker': blocker,
  'lease': {'holder': 'agent', 'epoch': 1, 'since': 1},
  'profile_key': 'default',
};

Future<void> _pump(WidgetTester tester, Widget home) {
  return tester.pumpWidget(
    MaterialApp(
      locale: const Locale('es'),
      theme: AppTheme.fromId('dark'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      home: home,
    ),
  );
}
