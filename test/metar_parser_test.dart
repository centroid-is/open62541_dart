import 'package:test/test.dart';

import '../example/metar_common.dart';

/// Unit tests for the METAR decoder used by the redundant-server example.
///
/// Every fixture is either a REAL observation captured from
/// `https://aviationweather.gov/api/data/metar` (noted as such) or a
/// SYNTHETIC report built to exercise one ugly corner of the format. Nothing
/// here touches the network — that is the whole reason the example's fetcher
/// sits behind [MetarSource].
void main() {
  // Fixed reference time so the DDHHMMZ group expands deterministically.
  final reference = DateTime.utc(2026, 9, 1, 19, 30);
  MetarObservation parse(String raw) => parseMetar(raw, referenceTime: reference);

  group('BIRK (Reykjavik Airport), real observations', () {
    test('CAVOK with a variable-direction group', () {
      // REAL, BIRK 2026-09-01 19:00Z. Exercises: CAVOK, the dddVddd variable
      // wind sector, and a Q (hPa) altimeter.
      final o = parse('METAR BIRK 011900Z 30003KT 250V350 CAVOK 10/02 Q1013');

      expect(o.station, 'BIRK');
      expect(o.reportType, 'METAR');
      expect(o.observationTime, DateTime.utc(2026, 9, 1, 19, 0));
      expect(o.windDirectionDeg, 300);
      expect(o.windVariable, isFalse);
      expect(o.windSpeedKt, 3);
      expect(o.windGustKt, isNull);
      expect(o.windVariableFromDeg, 250);
      expect(o.windVariableToDeg, 350);
      expect(o.cavok, isTrue);
      // CAVOK means "10 km or more", so the value is a floor, not a reading.
      expect(o.visibilityMeters, 10000);
      expect(o.visibilityIsMinimum, isTrue);
      expect(o.temperatureC, 10);
      expect(o.dewPointC, 2);
      expect(o.altimeterHPa, 1013);
      expect(o.skyLayers, isEmpty);
      expect(o.ceilingFeet, isNull);
      expect(o.flightCategory, FlightCategory.vfr);
      expect(o.relativeHumidityPercent, closeTo(57.5, 0.5));
      expect(o.unparsedGroups, isEmpty);
    });

    test('VRB wind: direction varying, no mean direction', () {
      // REAL, BIRK 2026-09-01 10:00Z. Exercises: VRB.
      final o = parse('METAR BIRK 011000Z VRB01KT CAVOK 09/03 Q1013');

      expect(o.windVariable, isTrue);
      expect(o.windDirectionDeg, isNull, reason: 'VRB has no mean direction');
      expect(o.windSpeedKt, 1);
      expect(o.flightCategory, FlightCategory.vfr);
    });

    test('cloud layers and a high broken ceiling', () {
      // REAL, BIRK 2026-09-01 17:00Z. Exercises: 9999 visibility, two cloud
      // layers, ceiling picked from BKN (not from FEW).
      final o = parse('METAR BIRK 011700Z 30005KT 9999 FEW034 BKN230 11/02 Q1013');

      expect(o.visibilityMeters, 10000);
      expect(o.visibilityIsMinimum, isTrue, reason: '9999 codes for "10 km or more"');
      expect(o.skyLayers.map((l) => l.toString()), ['FEW034', 'BKN230']);
      expect(o.skyLayers.first.isCeiling, isFalse);
      expect(o.ceilingFeet, 23000);
      expect(o.skyConditionText, 'FEW034 BKN230');
      expect(o.flightCategory, FlightCategory.vfr);
    });
  });

  group('winter / low-visibility corners', () {
    test('negative temperatures, gusts and a vertical-visibility ceiling', () {
      // SYNTHETIC, in the style of a BIRK winter storm. Exercises: M-prefixed
      // negative temperature AND dew point, a gust group, a 4-digit metric
      // visibility below 10 km, two present-weather groups, VV as ceiling.
      final o = parse('METAR BIRK 151200Z 09025G40KT 1200 +SN BLSN VV005 M04/M06 Q0978');

      expect(o.temperatureC, -4);
      expect(o.dewPointC, -6);
      expect(o.windDirectionDeg, 90);
      expect(o.windSpeedKt, 25);
      expect(o.windGustKt, 40);
      expect(o.visibilityMeters, 1200);
      expect(o.visibilityIsMinimum, isFalse);
      expect(o.presentWeather, ['+SN', 'BLSN']);
      expect(o.skyLayers.single.cover, 'VV');
      expect(o.ceilingFeet, 500, reason: 'vertical visibility counts as a ceiling');
      expect(o.altimeterHPa, 978);
      // 1200 m is 0.75 sm and the ceiling is 500 ft: LIFR on both counts.
      expect(o.flightCategory, FlightCategory.lifr);
    });

    test('fractional statute-mile visibility and an RVR group', () {
      // SYNTHETIC (US-format, KSFO-style fog). Exercises: `1/2SM`, an RVR
      // group that is recognised but not modelled, VV004, an inHg altimeter.
      final o = parse('METAR KSFO 011856Z 28016KT 1/2SM R28R/2000V4000FT FG VV004 14/13 A2989');

      expect(o.visibilityMeters, closeTo(804.7, 0.1));
      expect(o.visibilityStatuteMiles, closeTo(0.5, 1e-9));
      expect(o.presentWeather, ['FG']);
      expect(o.ceilingFeet, 400);
      // A2989 = 29.89 inHg = 1012.19 hPa.
      expect(o.altimeterHPa, closeTo(1012.19, 0.01));
      expect(o.unparsedGroups, ['R28R/2000V4000FT'], reason: 'RVR is kept, not silently dropped');
      expect(o.flightCategory, FlightCategory.lifr);
    });

    test('mixed-number visibility spanning two tokens ("1 1/2SM")', () {
      // SYNTHETIC (US format). Exercises: the whole+fraction visibility that
      // METAR writes as two whitespace-separated tokens.
      final o = parse('METAR KORD 011751Z 09006KT 1 1/2SM -RA BR OVC004 12/11 A2981');

      expect(o.visibilityStatuteMiles, closeTo(1.5, 1e-9));
      expect(o.visibilityMeters, closeTo(2414.0, 0.1));
      expect(o.presentWeather, ['-RA', 'BR']);
      expect(o.ceilingFeet, 400);
      expect(o.flightCategory, FlightCategory.lifr);
    });

    test('P6SM is a floor, M1/4SM is a ceiling on the value', () {
      // SYNTHETIC. Exercises: the P ("or more") and M ("less than") prefixes.
      expect(parse('METAR KDEN 011753Z 00000KT P6SM CLR 20/05 A3010').visibilityIsMinimum, isTrue);
      final low = parse('METAR KDEN 011753Z 00000KT M1/4SM FG VV001 02/02 A3010');
      expect(low.visibilityIsMinimum, isFalse);
      expect(low.visibilityStatuteMiles, closeTo(0.25, 1e-9));
      expect(low.flightCategory, FlightCategory.lifr);
    });
  });

  group('missing and degraded groups', () {
    test('AUTO station with every sensor reporting slashes', () {
      // SYNTHETIC, in the shape a fully automated station emits when its
      // sensors are out. Exercises: AUTO, `/////KT`, `////` visibility,
      // `//////` cloud, and a temperature group that still reports.
      final o = parse('METAR BIRK 200600Z AUTO /////KT //// ////// M02/M04 Q1001');

      expect(o.automatic, isTrue);
      expect(o.windDirectionDeg, isNull);
      expect(o.windSpeedKt, isNull);
      expect(o.windVariable, isFalse, reason: '/// is "not reported", not VRB');
      expect(o.visibilityMeters, isNull, reason: 'a missing reading must not become 0');
      expect(o.skyLayers, isEmpty);
      expect(o.temperatureC, -2);
      expect(o.dewPointC, -4);
      expect(o.altimeterHPa, 1001);
      // Neither ceiling nor visibility is known: refuse to guess a category.
      expect(o.flightCategory, FlightCategory.unknown);
    });

    test('missing temperature and dew point', () {
      // SYNTHETIC. Exercises: `/////` in the temperature slot and `Q////`.
      final o = parse('METAR BIRK 011200Z 27010KT 9999 SCT030 /////  Q////');

      expect(o.temperatureC, isNull);
      expect(o.dewPointC, isNull);
      expect(o.relativeHumidityPercent, isNull);
      expect(o.altimeterHPa, isNull);
      expect(o.windSpeedKt, 10);
    });

    test('a temperature group with only the dry-bulb reading', () {
      // SYNTHETIC. Exercises: `M04///`, i.e. temperature present, dew point
      // sensor out.
      final o = parse('METAR BIRK 011200Z 27010KT 9999 SCT030 M04/// Q1001');
      expect(o.temperatureC, -4);
      expect(o.dewPointC, isNull);
      expect(o.relativeHumidityPercent, isNull);
    });

    test('a station reporting nothing at all (NIL)', () {
      // SYNTHETIC but standard: a station that is up but has no observation.
      final o = parse('METAR BIRK 011200Z NIL');

      expect(o.nil, isTrue);
      expect(o.station, 'BIRK');
      expect(o.observationTime, DateTime.utc(2026, 9, 1, 12, 0));
      expect(o.temperatureC, isNull);
      expect(o.windSpeedKt, isNull);
      expect(o.flightCategory, FlightCategory.unknown);
    });

    test('a non-METAR string is rejected outright', () {
      expect(() => parseMetar('not a weather report'), throwsA(isA<MetarParseException>()));
      expect(() => parseMetar('   '), throwsA(isA<MetarParseException>()));
    });
  });

  group('report framing', () {
    test('SPECI, AUTO, remarks and the maintenance flag', () {
      // REAL, BGTL (Thule) 2026-09-01 18:56Z. Exercises: SPECI, AUTO, calm
      // wind (00000KT), three cloud layers, an inHg altimeter, an RMK section
      // that must be cut off, and the trailing `$` maintenance indicator.
      final o = parse(
        'SPECI BGTL 011856Z AUTO 00000KT 9999 FEW033 BKN043 OVC050 04/M01 A2986 '
        r'RMK AO2 DZE55 SLP093 TSNO $',
      );

      expect(o.reportType, 'SPECI');
      expect(o.automatic, isTrue);
      expect(o.windDirectionDeg, 0);
      expect(o.windSpeedKt, 0, reason: '00000KT is calm');
      expect(o.dewPointC, -1);
      expect(o.ceilingFeet, 4300);
      expect(o.unparsedGroups, isEmpty, reason: 'everything after RMK is discarded');
      expect(o.flightCategory, FlightCategory.vfr);
    });

    test('a COR correction is flagged', () {
      final o = parse('METAR COR BIRK 011900Z 30003KT CAVOK 10/02 Q1013');
      expect(o.corrected, isTrue);
      expect(o.station, 'BIRK');
    });

    test('a trend group ends the observation section', () {
      // REAL-shaped (EDDF). Exercises: metres-per-second wind AND the NOSIG
      // trend group, which must not be mistaken for an observation group.
      final o = parse('METAR EDDF 011920Z 25008MPS 9999 SCT030 18/12 Q1015 NOSIG');

      expect(o.windSpeedKt, closeTo(15.55, 0.01), reason: '8 m/s converted to knots');
      expect(o.unparsedGroups, ['NOSIG']);
      expect(o.altimeterHPa, 1015);
    });

    test('a TEMPO forecast section does not leak into the observation', () {
      final o = parse('METAR BIRK 011900Z 30003KT 9999 FEW020 10/02 Q1013 TEMPO 2000 -SHRA BKN008');

      expect(o.visibilityMeters, 10000, reason: 'the 2000 belongs to the forecast');
      expect(o.skyLayers.map((l) => l.toString()), ['FEW020']);
      expect(o.presentWeather, isEmpty);
      expect(o.unparsedGroups, ['TEMPO', '2000', '-SHRA', 'BKN008']);
      expect(o.flightCategory, FlightCategory.vfr);
    });

    test('the NOAA two-line text form parses, and its header pins the date', () {
      // REAL, exactly as served by
      // https://tgftp.nws.noaa.gov/data/observations/metar/stations/BIRK.TXT
      // Exercises: the plain-text fallback endpoint's format. The header line
      // gives the calendar date, so no reference time is needed.
      final o = parseMetar('2026/09/01 19:00\nBIRK 011900Z 30003KT 250V350 CAVOK 10/02 Q1013');

      expect(o.station, 'BIRK');
      expect(o.observationTime, DateTime.utc(2026, 9, 1, 19, 0));
      expect(o.temperatureC, 10);
      expect(o.cavok, isTrue);
    });

    test('a bulletin-terminated report (trailing =) parses', () {
      final o = parse('METAR BIKF 011930Z 32003KT CAVOK 09/03 Q1013=');
      expect(o.station, 'BIKF');
      expect(o.temperatureC, 9);
    });
  });

  group('derived values', () {
    test('the day-of-month group resolves to the most recent matching date', () {
      // Reference is 2026-09-01 19:30Z, so day 15 must be LAST month.
      final august = parseMetar('METAR BIRK 151200Z 30003KT CAVOK 10/02 Q1013', referenceTime: reference);
      expect(august.observationTime, DateTime.utc(2026, 8, 15, 12, 0));

      // A report from just before midnight, read just after: still yesterday.
      final justAfterMidnight = parseMetar(
        'METAR BIRK 312350Z 30003KT CAVOK 10/02 Q1013',
        referenceTime: DateTime.utc(2026, 9, 1, 0, 10),
      );
      expect(justAfterMidnight.observationTime, DateTime.utc(2026, 8, 31, 23, 50));
    });

    test('flight category thresholds', () {
      FlightCategory categoryOf(String tail) => parse('METAR BIRK 011900Z 00000KT $tail 10/02 Q1013').flightCategory;

      // Ceiling-driven.
      expect(categoryOf('9999 OVC004'), FlightCategory.lifr); // < 500 ft
      expect(categoryOf('9999 OVC008'), FlightCategory.ifr); // 500-999 ft
      expect(categoryOf('9999 OVC020'), FlightCategory.mvfr); // 1000-3000 ft
      expect(categoryOf('9999 OVC040'), FlightCategory.vfr); // > 3000 ft
      // Visibility-driven (with no ceiling at all).
      expect(categoryOf('0800 FEW040'), FlightCategory.lifr); // < 1 sm
      expect(categoryOf('3000 FEW040'), FlightCategory.ifr); // 1.86 sm
      expect(categoryOf('8000 FEW040'), FlightCategory.mvfr); // 4.97 sm
      expect(categoryOf('9999 FEW040'), FlightCategory.vfr);
    });

    test('relative humidity from temperature and dew point', () {
      expect(parse('METAR BIRK 011900Z 00000KT CAVOK 10/10 Q1013').relativeHumidityPercent, closeTo(100, 0.01));
      expect(parse('METAR BIRK 011900Z 00000KT CAVOK 20/10 Q1013').relativeHumidityPercent, closeTo(52.5, 0.5));
      expect(parse('METAR BIRK 011900Z 00000KT CAVOK M04/M06 Q1013').relativeHumidityPercent, closeTo(86.0, 0.5));
    });

    test('wind unit conversions', () {
      expect(parse('METAR BIRK 011900Z 25008MPS CAVOK 10/02 Q1013').windSpeedKt, closeTo(15.55, 0.01));
      expect(parse('METAR BIRK 011900Z 25020KMH CAVOK 10/02 Q1013').windSpeedKt, closeTo(10.8, 0.01));
      expect(parse('METAR BIRK 011900Z 25008G12MPS CAVOK 10/02 Q1013').windGustKt, closeTo(23.33, 0.01));
    });

    test('cloud layers keep their convective type', () {
      final o = parse('METAR BIRK 011900Z 00000KT 9999 SCT030CB BKN050TCU 10/02 Q1013');
      expect(o.skyLayers.first.type, 'CB');
      expect(o.skyLayers.last.type, 'TCU');
      expect(o.skyConditionText, 'SCT030CB BKN050TCU');
      expect(o.ceilingFeet, 5000);
    });

    test('a cloud layer with an unreported base is not a ceiling height', () {
      final o = parse('METAR BIRK 011900Z 00000KT 9999 BKN/// 10/02 Q1013');
      expect(o.skyLayers.single.cover, 'BKN');
      expect(o.skyLayers.single.baseFeet, isNull);
      expect(o.ceilingFeet, isNull);
    });
  });
}
