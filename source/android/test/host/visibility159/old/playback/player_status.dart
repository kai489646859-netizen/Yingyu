import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class PlayerStatusData {
  const PlayerStatusData({
    required this.time,
    this.rxBytesPerSecond,
    this.network = 'unknown',
    this.batteryPercent,
    this.charging,
  });
  final DateTime time;
  final double? rxBytesPerSecond;
  final String network;
  final int? batteryPercent;
  final bool? charging;

  factory PlayerStatusData.fromMap(Map<Object?, Object?>? values) {
    final rate = values?['rxBytesPerSecond'];
    final battery = values?['batteryPercent'];
    final wallTime = values?['wallTimeMs'];
    return PlayerStatusData(
      time:
          wallTime is num &&
              wallTime.isFinite &&
              wallTime > 0 &&
              wallTime <= 8640000000000000
          ? DateTime.fromMillisecondsSinceEpoch(wallTime.toInt())
          : DateTime.now(),
      rxBytesPerSecond: rate is num && rate.isFinite && rate >= 0
          ? rate.toDouble()
          : null,
      network: values?['network'] is String
          ? values!['network'] as String
          : 'unknown',
      batteryPercent: battery is int && battery >= 0 && battery <= 100
          ? battery
          : null,
      charging: values?['charging'] is bool
          ? values!['charging'] as bool
          : null,
    );
  }

  String get timeText =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  String get rateText {
    final rate = rxBytesPerSecond;
    if (rate == null) return '— KB/s';
    if (rate < 1024) return '${rate.round()} B/s';
    if (rate < 1024 * 1024) {
      final value = rate / 1024;
      return '${value.toStringAsFixed(value < 10 ? 1 : 0)} KB/s';
    }
    final value = rate / (1024 * 1024);
    return '${value.toStringAsFixed(value < 10 ? 1 : 0)} MB/s';
  }

  String get networkText => switch (network) {
    'wifi' => 'Wi-Fi',
    'cellular' => '蜂窝',
    'ethernet' => '有线',
    'vpn' => 'VPN',
    'bluetooth' => '蓝牙',
    'disconnected' => '断开',
    'connected' => '已连接',
    _ => '—',
  };
  IconData get networkIcon => switch (network) {
    'wifi' => Icons.wifi,
    'cellular' => Icons.network_cell,
    'ethernet' => Icons.lan_outlined,
    'vpn' => Icons.vpn_lock_outlined,
    'bluetooth' => Icons.bluetooth,
    'disconnected' => Icons.signal_wifi_off,
    'connected' => Icons.network_check,
    _ => Icons.help_outline,
  };
}

/// The player owns the visible/foreground policy. Native code never polls.
class PlayerStatusController extends ChangeNotifier {
  PlayerStatusController({
    Future<Map<Object?, Object?>?> Function()? read,
    Future<Map<Object?, Object?>?> Function()? readRate,
  }) : _read = read ?? _nativeRead,
       _readRate = readRate ?? read ?? _rateRead;
  static const channel = MethodChannel('yingyu/player-status');
  final Future<Map<Object?, Object?>?> Function() _read;
  final Future<Map<Object?, Object?>?> Function() _readRate;
  PlayerStatusData value = PlayerStatusData(time: DateTime.now());
  Timer? _timer;
  Timer? _deadline;
  Completer<Map<Object?, Object?>?>? _pending;
  bool _active = false, _busy = false, _disposed = false;
  bool _warm = false;
  int _generation = 0;
  static Future<Map<Object?, Object?>?> _nativeRead() =>
      channel.invokeMapMethod<Object?, Object?>('sample');
  static Future<Map<Object?, Object?>?> _rateRead() =>
      channel.invokeMapMethod<Object?, Object?>('rate');

  void setKeepRateWarm(bool warm) {
    if (_disposed || _warm == warm) return;
    _warm = warm;
    _schedule();
  }

  void setActive(bool active) {
    if (_disposed || _active == active) return;
    _active = active;
    _schedule();
  }

  void _schedule() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    if (!_active && !_warm) {
      _deadline?.cancel();
      final pending = _pending;
      if (pending != null && !pending.isCompleted) pending.complete(null);
      unawaited(channel.invokeMethod<void>('reset').catchError((Object _) {}));
      return;
    }
    unawaited(sample());
    _timer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(sample()),
    );
  }

  Future<void> sample() async {
    if (_disposed || (!_active && !_warm) || _busy) return;
    _busy = true;
    final generation = _generation;
    // All visible status refreshes at 1 Hz. Hidden controls only keep the
    // receive counter warm; native code averages actual recent byte deltas.
    final full = _active;
    final pending = Completer<Map<Object?, Object?>?>();
    _pending = pending;
    final deadline = Timer(const Duration(milliseconds: 700), () {
      if (!pending.isCompleted) pending.complete(null);
    });
    _deadline = deadline;
    unawaited(
      Future.sync(full ? _read : _readRate).then(
        (values) {
          if (!pending.isCompleted) pending.complete(values);
        },
        onError: (Object _, StackTrace _) {
          if (!pending.isCompleted) pending.complete(null);
        },
      ),
    );
    Map<Object?, Object?>? values;
    try {
      values = await pending.future;
    } catch (_) {
      // Unknown data never blocks playback or becomes a false zero.
    } finally {
      deadline.cancel();
      if (identical(_pending, pending)) {
        _pending = null;
        _deadline = null;
      }
      _busy = false;
    }
    if (_disposed || (!_active && !_warm)) return;
    if (generation != _generation) {
      // Showing controls can supersede an in-flight rate-only read. Complete
      // the new visible snapshot now instead of leaving it blank for a tick.
      unawaited(sample());
      return;
    }
    if (!full) {
      final rate = PlayerStatusData.fromMap(values).rxBytesPerSecond;
      value = PlayerStatusData(
        time: DateTime.now(),
        rxBytesPerSecond: rate,
        network: value.network,
        batteryPercent: value.batteryPercent,
        charging: value.charging,
      );
    } else {
      value = PlayerStatusData.fromMap(values);
    }
    if (_active) notifyListeners();
  }

  @override
  void dispose() {
    setKeepRateWarm(false);
    setActive(false);
    _disposed = true;
    _generation++;
    _timer?.cancel();
    super.dispose();
  }
}

class PlayerStatusBar extends StatelessWidget {
  const PlayerStatusBar({super.key, required this.data});
  final PlayerStatusData data;
  @override
  Widget build(BuildContext context) {
    final right = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: '本应用接收速率',
          child: Text(data.rateText, key: const Key('player-receive-rate')),
        ),
        const SizedBox(width: 12),
        Tooltip(
          message: '网络连接：${data.networkText}',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(data.networkIcon, size: 17),
              const SizedBox(width: 4),
              Text(data.networkText),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Tooltip(
          message: data.charging == true ? '电量（电源已连接）' : '电量',
          child: PlayerBattery(
            percent: data.batteryPercent,
            charging: data.charging == true,
          ),
        ),
      ],
    );
    return DefaultTextStyle(
      style: DefaultTextStyle.of(context).style.copyWith(
        color: Colors.white,
        fontSize: 12,
        fontWeight: FontWeight.w500,
      ),
      child: IconTheme(
        data: const IconThemeData(color: Colors.white),
        child: SizedBox(
          key: const Key('player-status-bar'),
          height: 24,
          child: LayoutBuilder(
            builder: (context, bounds) => bounds.maxWidth < 500
                ? Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [Text(data.timeText), right],
                  )
                : Stack(
                    children: [
                      Align(
                        alignment: Alignment.center,
                        child: Text(data.timeText),
                      ),
                      Align(alignment: Alignment.centerRight, child: right),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class PlayerBattery extends StatelessWidget {
  const PlayerBattery({super.key, this.percent, required this.charging});
  final int? percent;
  final bool charging;
  @override
  Widget build(BuildContext context) {
    final level = (percent ?? 0).clamp(0, 100) / 100;
    final fill = charging
        ? const Color(0xFF32D74B)
        : percent != null && percent! >= 0 && percent! <= 20
        ? const Color(0xFFFF453A)
        : Colors.white;
    return Semantics(
      label: '电量',
      value: '${percent ?? '未知'}${charging ? '，正在充电' : ''}',
      child: SizedBox(
        key: const Key('player-battery'),
        width: 26,
        height: 13,
        child: Stack(
          alignment: Alignment.centerLeft,
          children: [
            Positioned(
              right: 0,
              width: 2,
              height: 5,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: fill.withValues(alpha: .65),
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 3,
              top: 0,
              bottom: 0,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: fill.withValues(alpha: .8)),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(1.3),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(end: level),
                      duration: const Duration(milliseconds: 350),
                      curve: Curves.easeOut,
                      builder: (context, value, _) => Stack(
                        children: [
                          const Positioned.fill(
                            child: ColoredBox(color: Colors.white12),
                          ),
                          FractionallySizedBox(
                            widthFactor: value,
                            child: ColoredBox(
                              color: fill,
                              child: const SizedBox.expand(),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 1,
              right: 4,
              top: 0,
              bottom: 0,
              child: Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    transitionBuilder: (child, animation) =>
                        FadeTransition(opacity: animation, child: child),
                    child: SizedBox(
                      key: ValueKey(charging),
                      child: charging
                          ? Icon(
                              Icons.bolt,
                              key: const Key('player-battery-charging'),
                              size: 10,
                              color: level >= .6
                                  ? const Color(0xFF121419)
                                  : fill,
                              shadows: [
                                Shadow(
                                  color: level >= .6 ? fill : Colors.black,
                                  blurRadius: 2,
                                ),
                              ],
                            )
                          : null,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
