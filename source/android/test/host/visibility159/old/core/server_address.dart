import 'emby.dart';
import 'models.dart';

class ServerAddress {
  const ServerAddress(this.protocol, this.host, this.port, this.path);
  final String protocol, host, port, path;
  factory ServerAddress.parse(
    String value, {
    String defaultProtocol = 'http',
    String defaultPort = '8096',
  }) {
    final explicit = value.contains('://');
    final uri = Uri.tryParse(
      explicit ? value.trim() : '$defaultProtocol://${value.trim()}',
    );
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        RegExp(r'\s').hasMatch(uri.host)) {
      throw const AppFailure('地址格式不正确，请输入 IP 或域名');
    }
    final port = uri.hasPort
        ? uri.port
        : explicit
        ? (uri.scheme == 'https' ? 443 : 80)
        : int.tryParse(defaultPort.trim()) ?? 0;
    if (port < 1 || port > 65535) throw const AppFailure('端口应为 1–65535');
    return ServerAddress(uri.scheme, uri.host, '$port', uri.path);
  }
  String get address {
    final number = int.tryParse(port.trim());
    if (number == null || number < 1 || number > 65535) {
      throw const AppFailure('端口应为 1–65535');
    }
    if (host.trim().isEmpty || RegExp(r'[\s/?#@]').hasMatch(host)) {
      throw const AppFailure('请输入有效的 IP 或域名');
    }
    final value = Uri(
      scheme: protocol,
      host: host.trim(),
      port: number,
      path: path.isEmpty || path.startsWith('/') ? path : '/$path',
    );
    return normalizeServer(value.toString()).toString();
  }
}

