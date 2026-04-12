import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:enough_convert/windows.dart';
import 'package:path/path.dart' as p;

/// Rewrites text-based subtitle files as UTF-8 without BOM so ExoPlayer/mpv decode
/// Persian/Arabic and other scripts reliably (handles UTF-16 BOM, Windows-1256, mojibake).
Future<void> rewriteSubtitleFileAsUtf8(File file) async {
  final ext = p.extension(file.path).toLowerCase();
  if (!const {'.srt', '.vtt', '.ass', '.ssa'}.contains(ext)) {
    return;
  }
  final raw = await file.readAsBytes();
  final normalized = normalizeSubtitleBytesToUtf8(raw);
  if (normalized == null) {
    return;
  }
  if (!identical(normalized, raw) && !_bytesEqual(normalized, raw)) {
    await file.writeAsBytes(normalized, flush: true);
  }
}

bool _bytesEqual(Uint8List a, List<int> b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

/// Returns UTF-8 bytes (no BOM). [input] is consumed as a copy when output differs.
Uint8List? normalizeSubtitleBytesToUtf8(List<int> input) {
  if (input.isEmpty) {
    return null;
  }
  final bytes = Uint8List.fromList(input);

  // UTF-16 LE BOM
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    final text = _decodeUtf16Le(bytes.sublist(2));
    return Uint8List.fromList(utf8.encode(text));
  }
  // UTF-16 BE BOM
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    final text = _decodeUtf16Be(bytes.sublist(2));
    return Uint8List.fromList(utf8.encode(text));
  }

  var start = 0;
  if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
    start = 3;
  }
  final payload = bytes.sublist(start);

  final text = _decodeSubtitlePayload(payload);
  return Uint8List.fromList(utf8.encode(text));
}

String _decodeUtf16Le(List<int> bytes) {
  final buffer = StringBuffer();
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    final codeUnit = bytes[i] | (bytes[i + 1] << 8);
    if (codeUnit != 0 || i + 2 < bytes.length) {
      buffer.writeCharCode(codeUnit);
    }
  }
  return buffer.toString();
}

String _decodeUtf16Be(List<int> bytes) {
  final buffer = StringBuffer();
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    final codeUnit = (bytes[i] << 8) | bytes[i + 1];
    buffer.writeCharCode(codeUnit);
  }
  return buffer.toString();
}

typedef _EncCandidate = ({String label, String text});

String _decodeSubtitlePayload(List<int> payload) {
  if (payload.isEmpty) {
    return '';
  }

  // Most SRT/VTT today are UTF-8. Never re-interpret valid UTF-8 bytes as CP1256/Latin-1
  // (that corrupts Persian text in files like *_fa.srt).
  try {
    return utf8.decode(payload, allowMalformed: false);
  } catch (_) {
    /* invalid UTF-8 — fall back to legacy encodings */
  }

  final candidates = <_EncCandidate>[
    (label: 'cp1256', text: const Windows1256Codec(allowInvalid: true).decode(payload)),
    (label: 'utf8loose', text: utf8.decode(payload, allowMalformed: true)),
    (label: 'latin1', text: latin1.decode(payload, allowInvalid: true)),
  ];

  _EncCandidate best = candidates.first;
  var bestScore = _subtitleEncodingFitness(best.text);
  for (final c in candidates.skip(1)) {
    final s = _subtitleEncodingFitness(c.text);
    if (s > bestScore) {
      bestScore = s;
      best = c;
    } else if (s == bestScore) {
      best = _preferOnTie(best, c);
    }
  }

  return best.text;
}

_EncCandidate _preferOnTie(_EncCandidate a, _EncCandidate b) {
  int rank(String label) => switch (label) {
        'utf8loose' => 0,
        'cp1256' => 1,
        'latin1' => 2,
        _ => 9,
      };
  return rank(a.label) <= rank(b.label) ? a : b;
}

/// Higher is better: reward Arabic/Persian script, penalize replacement chars and C1 garbage.
int _subtitleEncodingFitness(String s) {
  final script = _arabicScriptScore(s);
  final fffd = '\uFFFD'.allMatches(s).length;
  var c1Garbage = 0;
  for (final r in s.runes) {
    if (r >= 0x80 && r <= 0x9f) {
      c1Garbage++;
    }
  }
  return script * 4 - fffd * 45 - c1Garbage * 2;
}

int _arabicScriptScore(String s) {
  var n = 0;
  for (final r in s.runes) {
    if (r >= 0x0600 && r <= 0x06ff) {
      n++;
    } else if (r >= 0x0750 && r <= 0x077f) {
      n++;
    } else if (r >= 0x08a0 && r <= 0x08ff) {
      n++;
    } else if (r >= 0xfb50 && r <= 0xfdff) {
      n++;
    } else if (r >= 0xfe70 && r <= 0xfeff) {
      n++;
    }
  }
  return n;
}
