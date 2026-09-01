/*
  METAR model, parser and data sources — shared by the redundant-server and
  failover-client examples.

  Deliberately free of any OPC UA import: this file is the "field device" side
  of the demo. The servers in `metar_redundant_server.dart` project it onto an
  OPC UA structured type; the tests exercise it with recorded fixtures and a
  fake source, so nothing under `test/` ever touches the network.

  METAR reference: WMO No. 306 / ICAO Annex 3, and the FAA's aviation weather
  handbook for the flight-category thresholds.
*/

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

/// FAA flight category, derived from ceiling and visibility.
enum FlightCategory {
  /// Ceiling > 3000 ft AND visibility > 5 sm.
  vfr('VFR'),

  /// Ceiling 1000-3000 ft and/or visibility 3-5 sm.
  mvfr('MVFR'),

  /// Ceiling 500-<1000 ft and/or visibility 1-<3 sm.
  ifr('IFR'),

  /// Ceiling <500 ft and/or visibility <1 sm.
  lifr('LIFR'),

  /// Neither ceiling nor visibility could be determined.
  unknown('UNKNOWN');

  const FlightCategory(this.code);

  /// The short code as used on aviation charts (`VFR`, `MVFR`, ...).
  final String code;
}

/// One reported cloud layer (or a vertical-visibility group).
class SkyLayer {
  const SkyLayer(this.cover, {this.baseFeet, this.type});

  /// `FEW`, `SCT`, `BKN`, `OVC`, `VV`, or a "no cloud" token such as `NSC`,
  /// `NCD`, `CLR`, `SKC`.
  final String cover;

  /// Layer base in feet AGL, or `null` when the report gave `///`.
  final int? baseFeet;

  /// `CB` or `TCU` when the layer is flagged as convective.
  final String? type;

  /// True when this layer counts as a ceiling (broken/overcast/vertical vis).
  bool get isCeiling => cover == 'BKN' || cover == 'OVC' || cover == 'VV';

  @override
  String toString() {
    if (baseFeet == null) return cover == 'VV' ? 'VV///' : cover;
    final hundreds = (baseFeet! ~/ 100).toString().padLeft(3, '0');
    return '$cover$hundreds${type ?? ''}';
  }
}

/// A decoded METAR observation.
///
/// Every measured field is nullable: real reports routinely omit groups, and a
/// `///`-style group means "the sensor did not report", which is different from
/// zero. The OPC UA projection in `metar_redundant_server.dart` maps these to
/// documented sentinels (NaN / -1) because an OPC UA struct member cannot be
/// null.
class MetarObservation {
  MetarObservation({
    required this.station,
    required this.rawText,
    this.observationTime,
    this.reportType = 'METAR',
    this.automatic = false,
    this.corrected = false,
    this.nil = false,
    this.temperatureC,
    this.dewPointC,
    this.windDirectionDeg,
    this.windVariable = false,
    this.windVariableFromDeg,
    this.windVariableToDeg,
    this.windSpeedKt,
    this.windGustKt,
    this.visibilityMeters,
    this.visibilityIsMinimum = false,
    this.cavok = false,
    this.altimeterHPa,
    this.skyLayers = const [],
    this.presentWeather = const [],
    this.unparsedGroups = const [],
  });

  /// ICAO station identifier, e.g. `BIRK`.
  final String station;

  /// The raw METAR text the fields were decoded from.
  final String rawText;

  /// Observation time (UTC). METAR only carries day-of-month + HH:MM, so the
  /// year/month are resolved against a reference time by the parser.
  final DateTime? observationTime;

  /// `METAR` or `SPECI`.
  final String reportType;

  /// `AUTO` — fully automated observation, no human augmentation.
  final bool automatic;

  /// `COR` — a correction to a previously issued report.
  final bool corrected;

  /// `NIL` — the station is reporting nothing at all.
  final bool nil;

  final double? temperatureC;
  final double? dewPointC;

  /// True wind direction in degrees, or `null` for `VRB` / `///`.
  final int? windDirectionDeg;

  /// `VRB` — direction varying, no mean direction reported.
  final bool windVariable;

  /// Endpoints of a `dddVddd` variable-direction group.
  final int? windVariableFromDeg;
  final int? windVariableToDeg;

  /// Mean wind speed in knots (converted from MPS/KMH when needed).
  final double? windSpeedKt;

  /// Gust speed in knots, or `null` when no `G` group was reported.
  final double? windGustKt;

  /// Prevailing visibility in metres (US reports in statute miles are
  /// converted).
  final double? visibilityMeters;

  /// True when the report said `9999` / `P6SM` / `CAVOK`, i.e. the value is a
  /// floor ("10 km or more"), not an exact measurement.
  final bool visibilityIsMinimum;

  /// `CAVOK` — visibility >= 10 km, no cloud below 5000 ft (or below the
  /// highest minimum sector altitude), no CB/TCU and no significant weather.
  final bool cavok;

  /// QNH in hectopascals (`A` groups in inHg are converted).
  final double? altimeterHPa;

  final List<SkyLayer> skyLayers;

  /// Present-weather groups as reported (`-RA`, `+TSRA`, `VCSH`, `BR`, ...).
  final List<String> presentWeather;

  /// Groups the parser recognised as "not modelled" (RVR, runway state, wind
  /// shear, trend groups). Kept so nothing is silently swallowed.
  final List<String> unparsedGroups;

  /// Lowest broken/overcast/vertical-visibility base in feet AGL. `null` when
  /// there is no ceiling (or none could be determined).
  int? get ceilingFeet {
    int? lowest;
    for (final layer in skyLayers) {
      if (!layer.isCeiling || layer.baseFeet == null) continue;
      if (lowest == null || layer.baseFeet! < lowest) lowest = layer.baseFeet;
    }
    return lowest;
  }

  /// Prevailing visibility in statute miles.
  double? get visibilityStatuteMiles => visibilityMeters == null ? null : visibilityMeters! / _metresPerStatuteMile;

  /// Relative humidity from temperature and dew point (Magnus-Tetens).
  double? get relativeHumidityPercent {
    final t = temperatureC, d = dewPointC;
    if (t == null || d == null) return null;
    double es(double c) => 6.112 * math.exp(17.67 * c / (c + 243.5));
    return (100.0 * es(d) / es(t)).clamp(0.0, 100.0);
  }

  /// FAA flight category from ceiling and visibility.
  ///
  /// A missing ceiling means "no ceiling reported" and is treated as
  /// unlimited; likewise a missing visibility. When *both* are missing the
  /// category is [FlightCategory.unknown] rather than an optimistic VFR.
  FlightCategory get flightCategory {
    final ceiling = ceilingFeet;
    final vis = visibilityStatuteMiles;
    if (ceiling == null && vis == null && !cavok) return FlightCategory.unknown;
    final c = ceiling ?? 1 << 20;
    final v = vis ?? 99.0;
    if (c < 500 || v < 1.0) return FlightCategory.lifr;
    if (c < 1000 || v < 3.0) return FlightCategory.ifr;
    if (c <= 3000 || v <= 5.0) return FlightCategory.mvfr;
    return FlightCategory.vfr;
  }

  /// The sky groups rendered back as METAR tokens, e.g. `FEW034 BKN230`.
  String get skyConditionText {
    if (skyLayers.isEmpty) return cavok ? 'CAVOK' : '';
    return skyLayers.map((l) => l.toString()).join(' ');
  }

  @override
  String toString() =>
      'MetarObservation($station @ ${observationTime?.toIso8601String()}, '
      '${temperatureC ?? '-'}/${dewPointC ?? '-'} C, '
      'wind ${windVariable ? 'VRB' : windDirectionDeg ?? '-'}@${windSpeedKt ?? '-'}kt'
      '${windGustKt != null ? ' G$windGustKt' : ''}, '
      'vis ${visibilityMeters?.toStringAsFixed(0) ?? '-'} m, '
      'QNH ${altimeterHPa?.toStringAsFixed(0) ?? '-'}, '
      '${skyConditionText.isEmpty ? 'no sky' : skyConditionText}, '
      '${flightCategory.code})';
}

/// Thrown when a string cannot be decoded as a METAR at all.
class MetarParseException implements Exception {
  MetarParseException(this.message, this.raw);
  final String message;
  final String raw;
  @override
  String toString() => 'MetarParseException: $message (raw: "$raw")';
}

const double _metresPerStatuteMile = 1609.344;
const double _knotsPerMps = 1.9438444924406;
const double _knotsPerKmh = 0.5399568034557;
const double _hPaPerInHg = 33.863886666667;

final RegExp _stationRe = RegExp(r'^[A-Z][A-Z0-9]{3}$');
final RegExp _timeRe = RegExp(r'^(\d{2})(\d{2})(\d{2})Z$');
final RegExp _windRe = RegExp(r'^(\d{3}|VRB|///)(\d{2,3}|//)(?:G(\d{2,3}))?(KT|MPS|KMH)$');
final RegExp _windVarRe = RegExp(r'^(\d{3})V(\d{3})$');
final RegExp _visMetresRe = RegExp(r'^(\d{4})(NDV|[NSEW]{1,2})?$');
final RegExp _visMilesRe = RegExp(r'^([MP])?(\d{1,2})(?:/(\d{1,2}))?SM$');
final RegExp _skyRe = RegExp(r'^(FEW|SCT|BKN|OVC)(\d{3}|///)(CB|TCU)?$');
final RegExp _vertVisRe = RegExp(r'^VV(\d{3}|///)$');
final RegExp _tempRe = RegExp(r'^(M?\d{1,2}|//)/(M?\d{1,2}|//)?$');
final RegExp _qnhRe = RegExp(r'^Q(\d{4}|////)$');
final RegExp _altimRe = RegExp(r'^A(\d{4}|////)$');
final RegExp _rvrRe = RegExp(r'^R\d{2}[LCR]?/.+$');
final RegExp _runwayStateRe = RegExp(r'^\d{6}$|^R\d{2}[LCR]?/[/\d]{6}$');
final RegExp _weatherRe = RegExp(
  r'^(-|\+|VC)?(MI|PR|BC|DR|BL|SH|TS|FZ)?'
  r'(DZ|RA|SN|SG|IC|PL|GR|GS|UP|BR|FG|FU|VA|DU|SA|HZ|PY|PO|SQ|FC|SS|DS)+$',
);
final RegExp _headerDateRe = RegExp(r'^(\d{4})/(\d{2})/(\d{2})\s+(\d{2}):(\d{2})$');
const Set<String> _noCloudTokens = {'SKC', 'CLR', 'NSC', 'NCD'};
const Set<String> _trendTokens = {'NOSIG', 'TEMPO', 'BECMG', 'FM', 'TL', 'AT'};

int? _int(String? s) {
  if (s == null || s.contains('/')) return null;
  return int.tryParse(s);
}

double? _signedTemp(String? s) {
  if (s == null || s.contains('/')) return null;
  final negative = s.startsWith('M');
  final digits = negative ? s.substring(1) : s;
  final v = int.tryParse(digits);
  if (v == null) return null;
  return (negative ? -v : v).toDouble();
}

/// Decodes a raw METAR report.
///
/// Accepts either a bare report (`METAR BIRK 011900Z ...`) or the two-line
/// form served by the NOAA text endpoint, whose first line is a
/// `YYYY/MM/DD HH:MM` header — when present that header resolves the
/// year/month for the day-of-month-only timestamp inside the report.
///
/// [referenceTime] pins the calendar month used to expand the `DDHHMMZ` group
/// (defaults to "now", UTC). Pass it in tests so fixtures decode
/// deterministically.
///
/// Throws [MetarParseException] when no station identifier can be found.
/// Everything softer than that — a missing group, an unrecognised token — is
/// tolerated: the corresponding field stays `null` and unknown groups are
/// collected in [MetarObservation.unparsedGroups].
MetarObservation parseMetar(String raw, {DateTime? referenceTime}) {
  final original = raw.trim();
  if (original.isEmpty) throw MetarParseException('empty report', raw);

  // Split off an optional NOAA header line.
  DateTime? headerTime;
  var body = original;
  final lines = original.split(RegExp(r'[\r\n]+')).where((l) => l.trim().isNotEmpty).toList();
  if (lines.length > 1) {
    final header = _headerDateRe.firstMatch(lines.first.trim());
    if (header != null) {
      headerTime = DateTime.utc(
        int.parse(header.group(1)!),
        int.parse(header.group(2)!),
        int.parse(header.group(3)!),
        int.parse(header.group(4)!),
        int.parse(header.group(5)!),
      );
      body = lines.sublist(1).join(' ');
    } else {
      body = lines.join(' ');
    }
  }

  // Remarks are free-form and country-specific; keep them out of the decoder.
  // Trailing `=` terminates a report in bulletin form, and `$` flags a station
  // needing maintenance.
  body = body.replaceAll('=', ' ').toUpperCase();
  final rmk = body.indexOf(' RMK');
  if (rmk >= 0) body = body.substring(0, rmk);

  final tokens = body.split(RegExp(r'\s+')).where((t) => t.isNotEmpty && t != r'$').toList();
  if (tokens.isEmpty) throw MetarParseException('no tokens', raw);

  var i = 0;
  var reportType = 'METAR';
  if (tokens[i] == 'METAR' || tokens[i] == 'SPECI') {
    reportType = tokens[i];
    i++;
  }
  var corrected = false;
  if (i < tokens.length && tokens[i] == 'COR') {
    corrected = true;
    i++;
  }
  if (i >= tokens.length || !_stationRe.hasMatch(tokens[i])) {
    throw MetarParseException('no ICAO station identifier', raw);
  }
  final station = tokens[i++];

  DateTime? observationTime;
  if (i < tokens.length) {
    final m = _timeRe.firstMatch(tokens[i]);
    if (m != null) {
      i++;
      observationTime = _resolveObservationTime(
        day: int.parse(m.group(1)!),
        hour: int.parse(m.group(2)!),
        minute: int.parse(m.group(3)!),
        reference: headerTime ?? referenceTime ?? DateTime.now().toUtc(),
      );
    }
  }

  var automatic = false;
  var nil = false;
  int? windDirectionDeg;
  var windVariable = false;
  int? windVariableFrom, windVariableTo;
  double? windSpeedKt, windGustKt;
  double? visibilityMeters;
  var visibilityIsMinimum = false;
  var cavok = false;
  double? temperatureC, dewPointC, altimeterHPa;
  final skyLayers = <SkyLayer>[];
  final weather = <String>[];
  final unparsed = <String>[];
  var seenTempGroup = false;
  var stopped = false;

  for (; i < tokens.length; i++) {
    final t = tokens[i];

    // A trend group (NOSIG / TEMPO ... / BECMG ...) ends the observation part;
    // everything after it is a forecast, not an observation.
    if (_trendTokens.contains(t)) {
      stopped = true;
    }
    if (stopped) {
      unparsed.add(t);
      continue;
    }

    if (t == 'AUTO') {
      automatic = true;
      continue;
    }
    if (t == 'COR') {
      corrected = true;
      continue;
    }
    if (t == 'NIL') {
      nil = true;
      continue;
    }
    if (t == 'CAVOK') {
      // CAVOK implies >= 10 km visibility, no significant cloud and no
      // significant weather. Model it as the 10 km floor with no sky layers.
      cavok = true;
      visibilityMeters = 10000;
      visibilityIsMinimum = true;
      continue;
    }
    if (t == 'NSW' || t == '//') {
      unparsed.add(t);
      continue;
    }

    final wind = _windRe.firstMatch(t);
    if (wind != null && windSpeedKt == null) {
      final dir = wind.group(1)!;
      windVariable = dir == 'VRB';
      windDirectionDeg = _int(dir == 'VRB' ? null : dir);
      final unit = wind.group(4)!;
      double toKnots(double v) => switch (unit) {
        'MPS' => v * _knotsPerMps,
        'KMH' => v * _knotsPerKmh,
        _ => v,
      };
      final speed = _int(wind.group(2));
      if (speed != null) windSpeedKt = toKnots(speed.toDouble());
      final gust = _int(wind.group(3));
      if (gust != null) windGustKt = toKnots(gust.toDouble());
      continue;
    }

    final varWind = _windVarRe.firstMatch(t);
    if (varWind != null) {
      windVariableFrom = int.parse(varWind.group(1)!);
      windVariableTo = int.parse(varWind.group(2)!);
      continue;
    }

    // Statute-mile visibility, optionally as "1 1/2SM" across two tokens.
    if (t.endsWith('SM') ||
        (RegExp(r'^\d$').hasMatch(t) && i + 1 < tokens.length && _visMilesRe.hasMatch(tokens[i + 1]))) {
      var whole = 0.0;
      var token = t;
      if (!t.endsWith('SM')) {
        whole = double.parse(t);
        token = tokens[++i];
      }
      final m = _visMilesRe.firstMatch(token);
      if (m == null) {
        unparsed.add(token);
        continue;
      }
      final prefix = m.group(1);
      final numerator = double.parse(m.group(2)!);
      final denominator = m.group(3) == null ? null : double.parse(m.group(3)!);
      final miles = whole + (denominator == null ? numerator : numerator / denominator);
      visibilityMeters = miles * _metresPerStatuteMile;
      // `P` = "or more", `M` = "less than"; both mean the number is a bound.
      visibilityIsMinimum = prefix == 'P';
      continue;
    }

    if (t == '////' && visibilityMeters == null) {
      // Visibility sensor not reporting; leave it null.
      continue;
    }

    final visM = _visMetresRe.firstMatch(t);
    if (visM != null && visibilityMeters == null && !seenTempGroup) {
      final metres = int.parse(visM.group(1)!);
      // 9999 is the coded value for "10 km or more".
      visibilityMeters = metres == 9999 ? 10000 : metres.toDouble();
      visibilityIsMinimum = metres == 9999;
      continue;
    }

    if (_rvrRe.hasMatch(t) || _runwayStateRe.hasMatch(t)) {
      unparsed.add(t);
      continue;
    }

    final sky = _skyRe.firstMatch(t);
    if (sky != null) {
      skyLayers.add(
        SkyLayer(
          sky.group(1)!,
          baseFeet: sky.group(2) == '///' ? null : int.parse(sky.group(2)!) * 100,
          type: sky.group(3),
        ),
      );
      continue;
    }
    final vv = _vertVisRe.firstMatch(t);
    if (vv != null) {
      skyLayers.add(SkyLayer('VV', baseFeet: vv.group(1) == '///' ? null : int.parse(vv.group(1)!) * 100));
      continue;
    }
    if (_noCloudTokens.contains(t)) {
      skyLayers.add(SkyLayer(t));
      continue;
    }
    if (t == '///' || t == '//////') {
      // Cloud sensor not reporting.
      continue;
    }

    final temp = _tempRe.firstMatch(t);
    if (temp != null && !seenTempGroup) {
      seenTempGroup = true;
      temperatureC = _signedTemp(temp.group(1));
      dewPointC = _signedTemp(temp.group(2));
      continue;
    }

    final qnh = _qnhRe.firstMatch(t);
    if (qnh != null) {
      final v = _int(qnh.group(1));
      if (v != null) altimeterHPa = v.toDouble();
      continue;
    }
    final altim = _altimRe.firstMatch(t);
    if (altim != null) {
      final v = _int(altim.group(1));
      // `A2992` is inches of mercury in hundredths.
      if (v != null) altimeterHPa = v / 100.0 * _hPaPerInHg;
      continue;
    }

    if (_weatherRe.hasMatch(t)) {
      weather.add(t);
      continue;
    }

    unparsed.add(t);
  }

  return MetarObservation(
    station: station,
    rawText: original,
    observationTime: observationTime,
    reportType: reportType,
    automatic: automatic,
    corrected: corrected,
    nil: nil,
    temperatureC: temperatureC,
    dewPointC: dewPointC,
    windDirectionDeg: windDirectionDeg,
    windVariable: windVariable,
    windVariableFromDeg: windVariableFrom,
    windVariableToDeg: windVariableTo,
    windSpeedKt: windSpeedKt,
    windGustKt: windGustKt,
    visibilityMeters: visibilityMeters,
    visibilityIsMinimum: visibilityIsMinimum,
    cavok: cavok,
    altimeterHPa: altimeterHPa,
    skyLayers: List.unmodifiable(skyLayers),
    presentWeather: List.unmodifiable(weather),
    unparsedGroups: List.unmodifiable(unparsed),
  );
}

/// Expands a `DDHHMM` group into a full UTC timestamp near [reference].
///
/// A report can arrive slightly *after* midnight UTC carrying yesterday's day
/// number, so try the reference month, then the previous one, and keep the
/// candidate closest to (but not far ahead of) [reference].
DateTime _resolveObservationTime({
  required int day,
  required int hour,
  required int minute,
  required DateTime reference,
}) {
  final ref = reference.toUtc();
  final candidates = <DateTime>[];
  for (final monthOffset in [0, -1, 1]) {
    final base = DateTime.utc(ref.year, ref.month + monthOffset, 1);
    // `hour == 24` is legal METAR for midnight at the end of the day.
    final candidate = DateTime.utc(base.year, base.month, day, hour, minute);
    if (candidate.day == day || hour == 24) candidates.add(candidate);
  }
  if (candidates.isEmpty) return DateTime.utc(ref.year, ref.month, day, hour, minute);
  candidates.sort((a, b) {
    // Prefer the most recent candidate that is not in the future; a report
    // stamped up to an hour ahead is normal clock skew and still counts.
    final grace = const Duration(hours: 1);
    final aFuture = a.isAfter(ref.add(grace));
    final bFuture = b.isAfter(ref.add(grace));
    if (aFuture != bFuture) return aFuture ? 1 : -1;
    return b.difference(ref).abs().compareTo(a.difference(ref).abs()) * -1;
  });
  return candidates.first;
}

/// Where a server gets its METAR from.
///
/// The whole point of this interface is that the servers never construct an
/// HTTP client themselves: the examples inject [AviationWeatherMetarSource]
/// (real network) and the tests inject a fake, so the test suite runs offline.
abstract class MetarSource {
  /// The ICAO station this source reports for.
  String get station;

  /// Fetches the latest observation. Throws on any failure (network,
  /// HTTP status, unparseable body, station reporting nothing) — the server
  /// turns a throw into `Bad_NoCommunication` over its last known value.
  Future<MetarObservation> fetch();

  /// Releases any underlying resources.
  void close() {}
}

/// The NOAA / Aviation Weather Center public METAR API.
///
/// `https://aviationweather.gov/api/data/metar?ids=<ICAO>&format=json` — US
/// government public-domain data, no API key, no registration. Their published
/// guidelines ask for a custom User-Agent and at most 100 requests/minute; the
/// examples poll every few minutes, which is well inside that (METARs are only
/// issued every 30-60 minutes anyway).
///
/// [useRawTextEndpoint] switches to the plain-text mirror
/// `https://tgftp.nws.noaa.gov/data/observations/metar/stations/<ICAO>.TXT`,
/// which serves the same report as a two-line text file. Both paths end up in
/// the same [parseMetar], which is exactly why the parser reads the raw report
/// rather than the JSON convenience fields.
class AviationWeatherMetarSource implements MetarSource {
  AviationWeatherMetarSource(
    this.station, {
    http.Client? httpClient,
    this.useRawTextEndpoint = false,
    this.timeout = const Duration(seconds: 15),
    this.userAgent = 'open62541_dart-metar-example/1.0 (+https://github.com/centroid-is/open62541_dart)',
  }) : _http = httpClient ?? http.Client(),
       _ownsClient = httpClient == null;

  @override
  final String station;

  final bool useRawTextEndpoint;
  final Duration timeout;
  final String userAgent;
  final http.Client _http;
  final bool _ownsClient;

  @override
  Future<MetarObservation> fetch() async {
    final uri = useRawTextEndpoint
        ? Uri.parse('https://tgftp.nws.noaa.gov/data/observations/metar/stations/$station.TXT')
        : Uri.https('aviationweather.gov', '/api/data/metar', {'ids': station, 'format': 'json'});

    final response = await _http.get(uri, headers: {'User-Agent': userAgent}).timeout(timeout);
    if (response.statusCode == 204) {
      throw MetarParseException('station $station is reporting nothing (HTTP 204)', '');
    }
    if (response.statusCode != 200) {
      throw HttpException('${uri.host} answered HTTP ${response.statusCode}');
    }

    if (useRawTextEndpoint) return parseMetar(response.body);

    final decoded = jsonDecode(response.body);
    if (decoded is! List || decoded.isEmpty) {
      throw MetarParseException('station $station is reporting nothing', response.body);
    }
    final entry = decoded.first as Map<String, dynamic>;
    final rawOb = entry['rawOb'];
    if (rawOb is! String || rawOb.trim().isEmpty) {
      throw MetarParseException('no rawOb in the API response', response.body);
    }
    // `reportTime` gives an unambiguous calendar date for the DDHHMMZ group.
    final reportTime = entry['reportTime'] is String
        ? DateTime.tryParse('${entry['reportTime']}Z'.replaceAll('ZZ', 'Z'))
        : null;
    return parseMetar(rawOb, referenceTime: reportTime?.toUtc());
  }

  @override
  void close() {
    if (_ownsClient) _http.close();
  }
}

/// Minimal HTTP failure type (avoids pulling `dart:io` into this file so it
/// stays usable from any platform the package supports).
class HttpException implements Exception {
  HttpException(this.message);
  final String message;
  @override
  String toString() => 'HttpException: $message';
}
