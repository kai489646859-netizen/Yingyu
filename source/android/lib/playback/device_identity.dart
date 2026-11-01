/// System declarations only. A model code is not a verified retail name.
class DeviceIdentity {
  const DeviceIdentity({
    this.manufacturer = '',
    this.brand = '',
    this.model = '',
    this.androidRelease = '',
    this.sdk = 0,
  });
  final String manufacturer, brand, model, androidRelease;
  final int sdk;

  factory DeviceIdentity.parse(Object? raw) {
    if (raw is! Map) return const DeviceIdentity();
    String field(String key) {
      final value = raw[key];
      if (value is! String) return '';
      final text = value.trim();
      if (text.isEmpty ||
          text.length > 80 ||
          const {'unknown', 'null', 'n/a'}.contains(text.toLowerCase()) ||
          RegExp(r'[\x00-\x1f\x7f;；\[\]]').hasMatch(text)) {
        return '';
      }
      return text;
    }

    final api = raw['sdk'];
    return DeviceIdentity(
      manufacturer: field('manufacturer'),
      brand: field('brand'),
      model: field('model'),
      androidRelease: field('androidRelease'),
      sdk: api is int && api > 0 && api < 1000 ? api : 0,
    );
  }

  static String shown(String value) => value.isEmpty ? '未提供' : value;
  String get system => [
    if (androidRelease.isNotEmpty) 'Android $androidRelease',
    if (sdk > 0) 'API $sdk',
  ].join(' · ');
  String get diagnostic =>
      '设备信息（系统报告）：'
      '制造商=${shown(manufacturer)}；品牌=${shown(brand)}；'
      '型号=${shown(model)}；系统=${shown(system)}；未推断营销名称';
}
