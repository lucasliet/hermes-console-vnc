import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../screen/screen_controller.dart';
import '../screen/screen_server.dart';
import '../screen/takeover_view.dart';
import '../services/tui_gateway_client.dart';
import '../theme/app_theme.dart';
import '../widgets/console_loader.dart';
import '../widgets/hermes_app_bar.dart';

enum _Phase { checking, stopped, starting, acquiring, active, failed }

/// Full control of the bot's desktop over the display websocket.
class TakeoverScreen extends StatefulWidget {
  /// Creates a takeover for [controller].
  const TakeoverScreen({
    required this.controller,
    this.profile = '',
    this.readOnly = false,
    super.key,
  });

  /// Shared display client, kept alive by the peek route underneath.
  final ScreenController controller;

  /// Active Hermes profile. Empty uses the gateway default.
  final String profile;

  /// A read-only connection can open this screen but cannot start or acquire.
  final bool readOnly;

  @override
  State<TakeoverScreen> createState() => _TakeoverScreenState();
}

class _TakeoverScreenState extends State<TakeoverScreen>
    with WidgetsBindingObserver {
  ScreenAssetServer? _server;
  DisplaySession? _session;
  StreamSubscription<DisplayLeaseInfo>? _events;
  var _phase = _Phase.checking;
  var _blocked = false;
  var _releasedByOther = false;
  var _holding = false;
  var _ourViewerHash = '';
  ScreenFailureKind? _failure;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_prepare());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) _releaseLease();
  }

  void _releaseLease() {
    final session = _session;
    if (session == null) return;
    _session = null;
    unawaited(
      widget.controller
          .release(session.viewerId, profile: widget.profile)
          .then<DisplayLeaseInfo>(
            (lease) => lease,
            onError: (_) => DisplayLeaseInfo.empty,
          ),
    );
  }

  Future<void> _prepare() async {
    if (widget.readOnly) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _failure = ScreenFailureKind.readOnly;
      });
      return;
    }
    try {
      final runtime = await widget.controller.status(profile: widget.profile);
      if (!mounted) return;
      if (!runtime.supported || !runtime.installed) {
        setState(() {
          _phase = _Phase.failed;
          _failure = ScreenFailureKind.unsupported;
        });
        return;
      }
      if (!runtime.running) {
        setState(() {
          _phase = _Phase.stopped;
          _blocked = runtime.blocker.isNotEmpty;
          _failure = null;
        });
        return;
      }
      await _acquire();
    } catch (error) {
      if (!mounted) return;
      setState(() => _fail(error));
    }
  }

  Future<void> _startDisplay() async {
    if (widget.readOnly || _blocked) return;
    setState(() {
      _phase = _Phase.starting;
      _failure = null;
    });
    try {
      await widget.controller.start(profile: widget.profile);
      if (!mounted) return;
      await _acquire();
    } catch (error) {
      if (!mounted) return;
      setState(() => _fail(error));
    }
  }

  Future<void> _acquire() async {
    setState(() {
      _phase = _Phase.acquiring;
      _releasedByOther = false;
    });
    final session = await widget.controller.observe(profile: widget.profile);
    final lease = await widget.controller.acquire(
      session.viewerId,
      profile: widget.profile,
    );
    final server = await ScreenAssetServer.start();
    if (!mounted) {
      await server.dispose();
      unawaited(
        widget.controller
            .release(session.viewerId, profile: widget.profile)
            .then<DisplayLeaseInfo>(
              (value) => value,
              onError: (_) => DisplayLeaseInfo.empty,
            ),
      );
      return;
    }
    await _events?.cancel();
    _events = widget.controller.watchLease().listen(
      _onLease,
      onError: (Object _) {},
    );
    _session = session;
    _server = server;
    _ourViewerHash = lease.viewerHash;
    _holding = lease.heldByHuman;
    setState(() => _phase = _Phase.active);
  }

  void _onLease(DisplayLeaseInfo lease) {
    if (!mounted || _phase != _Phase.active) return;
    if (!displayLeaseTakenOver(lease, ourViewerHash: _ourViewerHash)) return;
    setState(() => _releasedByOther = true);
  }

  void _releaseAndClose() {
    _releaseLease();
    if (mounted) Navigator.of(context).pop();
  }

  void _fail(Object error) {
    _failure = error is ScreenControllerException
        ? error.kind
        : error is TuiGatewayRpcError && error.code == -32601
        ? ScreenFailureKind.unsupported
        : ScreenFailureKind.unavailable;
    _phase = _Phase.failed;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_events?.cancel() ?? Future<void>.value());
    _releaseLease();
    unawaited(_server?.dispose() ?? Future<void>.value());
    super.dispose();
  }

  Uri _pageUri(Strings strings) {
    final session = _session!;
    final server = _server!;
    final ws = widget.controller
        .displayWsUri(session.path, session.ticket)
        .toString();
    return server.pageUri(ws, copy: _bridgeCopy(strings));
  }

  Map<String, String> _bridgeCopy(Strings strings) => {
    'connecting': strings.screenBridgeConnecting,
    'missing': strings.screenBridgeMissing,
    'closed': strings.screenBridgeClosed,
    'lost': strings.screenBridgeLost,
    'security': strings.screenBridgeSecurity,
    'credentials': strings.screenBridgeCredentials,
  };

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final active = _phase == _Phase.active;
    return Scaffold(
      backgroundColor: active ? const Color(0xFF000000) : colors.background,
      appBar: HermesAppBar(
        title: Text(strings.screenTakeoverTitle),
        backgroundColor: active ? const Color(0xFF000000) : null,
        foregroundColor: active ? const Color(0xFFFFFFFF) : null,
        actions: [
          if (active)
            TextButton.icon(
              onPressed: _releaseAndClose,
              icon: const Icon(Icons.back_hand_outlined, size: 18),
              label: Text(strings.screenHandBack),
            ),
        ],
      ),
      body: SafeArea(
        child: switch (_phase) {
          _Phase.active => Column(
            children: [
              _banner(strings, colors),
              Expanded(child: TakeoverView(pageUri: _pageUri(strings))),
            ],
          ),
          _Phase.stopped => _Centered(
            colors: colors,
            icon: Icons.desktop_windows_outlined,
            message: _blocked ? strings.screenBlocked : strings.screenStopped,
            action: _blocked
                ? null
                : FilledButton.icon(
                    onPressed: () => unawaited(_startDisplay()),
                    icon: const Icon(Icons.play_arrow),
                    label: Text(strings.screenStartDisplay),
                  ),
          ),
          _Phase.starting => _Centered(
            colors: colors,
            icon: Icons.power_settings_new,
            message: strings.screenStarting,
            busy: true,
          ),
          _Phase.acquiring => _Centered(
            colors: colors,
            icon: Icons.front_hand_outlined,
            message: strings.screenAcquiring,
            busy: true,
          ),
          _Phase.checking => _Centered(
            colors: colors,
            icon: Icons.monitor_outlined,
            message: strings.screenChecking,
            busy: true,
          ),
          _Phase.failed => _Centered(
            colors: colors,
            icon: Icons.error_outline,
            message: _failureText(strings, _failure),
            action: FilledButton.tonalIcon(
              onPressed: () {
                setState(() => _phase = _Phase.checking);
                unawaited(_prepare());
              },
              icon: const Icon(Icons.refresh),
              label: Text(strings.screenRetry),
            ),
          ),
        },
      ),
    );
  }

  Widget _banner(Strings strings, HermesThemeColors colors) {
    final lost = _releasedByOther;
    final message = lost
        ? strings.screenLeaseLost
        : _holding
        ? strings.screenActiveHint
        : strings.screenLeaseAgent;
    return Container(
      width: double.infinity,
      color: lost ? colors.error : colors.surfaceVariant,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Text(
        message,
        style: TextStyle(
          fontSize: 12,
          color: lost ? const Color(0xFFFFFFFF) : colors.textPrimary,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}

String _failureText(Strings strings, ScreenFailureKind? kind) {
  return switch (kind) {
    ScreenFailureKind.unsupported => strings.screenUnsupportedDetail,
    ScreenFailureKind.readOnly => strings.screenReadOnly,
    ScreenFailureKind.invalidResponse ||
    ScreenFailureKind.unavailable ||
    null => strings.screenTakeoverFailed,
  };
}

class _Centered extends StatelessWidget {
  const _Centered({
    required this.colors,
    required this.icon,
    required this.message,
    this.busy = false,
    this.action,
  });

  final HermesThemeColors colors;
  final IconData icon;
  final String message;
  final bool busy;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy)
              const ConsoleLoader.large()
            else
              Icon(icon, size: 48, color: colors.accent),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                height: 1.45,
                color: colors.textSecondary,
              ),
            ),
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    );
  }
}
