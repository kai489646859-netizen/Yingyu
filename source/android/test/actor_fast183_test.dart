import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:yingyu/core/emby.dart';
import 'core_test.dart' show syntheticSession, response;

void main() {
  test('known actor is returned before stalled directory scan', () async {
    final api = EmbyClient(
      client: MockClient((r) async {
        if (!r.url.queryParameters.containsKey('SearchTerm')) {
          return Completer<Never>().future;
        }
        return response(
          '{"Items":[{"Id":"actor","Name":"周星驰","Type":"Person"}],"TotalRecordCount":1}',
          200,
        );
      }),
    )..session = syntheticSession();
    final result = await api
        .searchPeople('周星驰')
        .timeout(const Duration(milliseconds: 300));
    expect(result.items.single.title, '周星驰');
    api.close();
  });
}
