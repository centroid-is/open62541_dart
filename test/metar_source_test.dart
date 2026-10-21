import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import '../example/metar_common.dart';

/// The feed adapter of the redundant-server example, against a scripted
/// HTTP client: one JSON request for the whole station set, silent stations
/// absent from the answer, and the plain-text mirror fetched per station.
/// Nothing here touches the network.
void main() {
  const stations = ['BIRK', 'BIKF', 'BIRG'];

  String entry(String icao, String rawOb, String reportTime) =>
      jsonEncode({'icaoId': icao, 'rawOb': rawOb, 'reportTime': reportTime});

  group('AviationWeatherMetarSource, JSON API', () {
    test('asks for every station in one request and keys the answer by station', () async {
      final requests = <Uri>[];
      final client = MockClient((request) async {
        requests.add(request.url);
        expect(request.headers['User-Agent'], contains('open62541_dart'));
        // BIRG is silent: the API simply has no entry for it.
        return http.Response(
          '[${entry('BIRK', 'METAR BIRK 211900Z 30003KT CAVOK 10/02 Q1013', '2026-10-21 19:00:00')},'
          '${entry('BIKF', 'METAR BIKF 211830Z 18012KT 9999 BKN040 05/01 Q0998', '2026-10-21 18:30:00')}]',
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final source = AviationWeatherMetarSource(stations, httpClient: client);

      final observations = await source.fetch();
      expect(requests, hasLength(1), reason: 'one request per poll, not one per station');
      expect(requests.single.host, 'aviationweather.gov');
      expect(requests.single.path, '/api/data/metar');
      expect(requests.single.queryParameters, {'ids': 'BIRK,BIKF,BIRG', 'format': 'json'});

      expect(observations.keys, unorderedEquals(['BIRK', 'BIKF']));
      expect(observations['BIRK']!.temperatureC, 10);
      expect(observations['BIRK']!.observationTime, DateTime.utc(2026, 10, 21, 19, 0));
      expect(observations['BIKF']!.windSpeedKt, 12);
      expect(observations['BIKF']!.observationTime, DateTime.utc(2026, 10, 21, 18, 30));
      expect(observations.containsKey('BIRG'), isFalse, reason: 'silent, not an error');
      expect(source.stations, stations);
    });

    test('an empty answer (nobody reporting) is a successful fetch with no observations', () async {
      final source = AviationWeatherMetarSource(
        stations,
        httpClient: MockClient((_) async => http.Response('[]', 200)),
      );
      expect(await source.fetch(), isEmpty);
      final noContent = AviationWeatherMetarSource(
        stations,
        httpClient: MockClient((_) async => http.Response('', 204)),
      );
      expect(await noContent.fetch(), isEmpty);
    });

    test('a station not asked for, and the older of two reports for one station, are dropped', () async {
      final source = AviationWeatherMetarSource(
        ['BIRK'],
        httpClient: MockClient(
          (_) async => http.Response(
            '[${entry('BIRK', 'METAR BIRK 211800Z 30003KT CAVOK 09/02 Q1013', '2026-10-21 18:00:00')},'
            '${entry('BIRK', 'METAR BIRK 211900Z 30003KT CAVOK 10/02 Q1013', '2026-10-21 19:00:00')},'
            '${entry('EGLL', 'METAR EGLL 211850Z 24008KT 9999 SCT030 14/09 Q1020', '2026-10-21 18:50:00')}]',
            200,
          ),
        ),
      );
      final observations = await source.fetch();
      expect(observations.keys, ['BIRK']);
      expect(observations['BIRK']!.temperatureC, 10, reason: 'the newest report wins');
    });

    test('an HTTP error or a non-array body is a feed failure', () async {
      final down = AviationWeatherMetarSource(stations, httpClient: MockClient((_) async => http.Response('', 503)));
      await expectLater(down.fetch(), throwsA(isA<HttpException>()));
      final garbage = AviationWeatherMetarSource(
        stations,
        httpClient: MockClient((_) async => http.Response('{"error": "x"}', 200)),
      );
      await expectLater(garbage.fetch(), throwsA(isA<MetarParseException>()));
    });

    test('identifiers are upper-cased and an empty set is refused', () {
      expect(
        AviationWeatherMetarSource([
          'birk',
          'bikf',
        ], httpClient: MockClient((_) async => http.Response('[]', 200))).stations,
        ['BIRK', 'BIKF'],
      );
      expect(() => AviationWeatherMetarSource(const []), throwsArgumentError);
    });
  });

  group('AviationWeatherMetarSource, plain-text mirror', () {
    test('fetches one file per station and treats a missing file as a silent station', () async {
      final requested = <String>[];
      final client = MockClient((request) async {
        requested.add(request.url.pathSegments.last);
        return switch (request.url.pathSegments.last) {
          'BIRK.TXT' => http.Response('2026/10/21 19:00\nBIRK 211900Z 30003KT CAVOK 10/02 Q1013\n', 200),
          'BIKF.TXT' => http.Response('2026/10/21 18:30\nBIKF 211830Z 18012KT 9999 BKN040 05/01 Q0998\n', 200),
          _ => http.Response('not found', 404),
        };
      });
      final source = AviationWeatherMetarSource(stations, httpClient: client, useRawTextEndpoint: true);
      final observations = await source.fetch();
      expect(requested, unorderedEquals(['BIRK.TXT', 'BIKF.TXT', 'BIRG.TXT']));
      expect(observations.keys, unorderedEquals(['BIRK', 'BIKF']));
      expect(observations['BIRK']!.observationTime, DateTime.utc(2026, 10, 21, 19, 0));
      expect(observations['BIKF']!.altimeterHPa, 998);
    });

    test('fails only when every station failed', () async {
      var calls = 0;
      final flaky = AviationWeatherMetarSource(
        ['BIRK', 'BIKF'],
        useRawTextEndpoint: true,
        httpClient: MockClient((request) async {
          calls++;
          return request.url.pathSegments.last == 'BIRK.TXT'
              ? http.Response('2026/10/21 19:00\nBIRK 211900Z 30003KT CAVOK 10/02 Q1013\n', 200)
              : http.Response('', 500);
        }),
      );
      final partial = await flaky.fetch();
      expect(calls, 2);
      expect(partial.keys, ['BIRK'], reason: 'one broken file does not take the feed down');

      final dead = AviationWeatherMetarSource(
        ['BIRK', 'BIKF'],
        useRawTextEndpoint: true,
        httpClient: MockClient((_) async => http.Response('', 500)),
      );
      await expectLater(dead.fetch(), throwsA(isA<HttpException>()));
    });
  });
}
