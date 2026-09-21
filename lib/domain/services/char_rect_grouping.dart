import 'dart:math' as math;

import '../entities/entities.dart';

/// Groups character rectangles into one rectangle per run of text, so a
/// highlight is drawn as a few bars instead of one box per glyph (FR-90).
///
/// Both horizontal and vertical writing are handled. The direction is taken
/// from the geometry rather than from the PDF's own text direction, because
/// Japanese documents frequently leave that unset or wrong, and a selection
/// can cross runs with different directions.
List<HighlightRect> groupCharRects(List<HighlightRect> chars) {
  final out = <HighlightRect>[];
  HighlightRect? run;
  var direction = _Direction.unknown;
  for (final c in chars) {
    if (_isEmpty(c)) continue;
    if (run == null) {
      run = c;
      direction = _Direction.unknown;
      continue;
    }
    final next = _continues(run, c, direction);
    if (next == null) {
      out.add(run);
      run = c;
      direction = _Direction.unknown;
    } else {
      run = _merge(run, c);
      direction = next;
    }
  }
  if (run != null) out.add(run);
  return out;
}

/// Which way a run of text is growing. A run keeps its direction once the
/// second character sets it: otherwise a line break in horizontal text looks
/// exactly like the next character of a vertical column, since both sit below
/// the run and overlap it horizontally.
enum _Direction { unknown, horizontal, vertical }

bool _isEmpty(HighlightRect r) => r.right <= r.left || r.top <= r.bottom;

double _width(HighlightRect r) => r.right - r.left;

double _height(HighlightRect r) => r.top - r.bottom;

/// The direction [run] continues in when [c] belongs to it, or null when [c]
/// starts a new run.
///
/// PDF page coordinates put the origin at the bottom left, so `top` is the
/// larger y.
_Direction? _continues(
  HighlightRect run,
  HighlightRect c,
  _Direction direction,
) {
  if (direction != _Direction.vertical && _sameLine(run, c)) {
    return _Direction.horizontal;
  }
  if (direction != _Direction.horizontal && _sameColumn(run, c)) {
    return _Direction.vertical;
  }
  return null;
}

/// 横書き: 同じ行に乗っていて、字送りが飛んでいない。段組みの隣の段へ
/// 飛ぶと gap が大きくなり、別の帯になる。
bool _sameLine(HighlightRect run, HighlightRect c) {
  final overlap = math.min(run.top, c.top) - math.max(run.bottom, c.bottom);
  final minHeight = math.min(_height(run), _height(c));
  if (overlap <= minHeight * 0.4) return false;
  final gap = c.left - run.right;
  return gap < math.min(_width(run), _width(c)) * 1.5;
}

/// 縦書き: 同じ列に乗っていて、行送りが飛んでいない。
bool _sameColumn(HighlightRect run, HighlightRect c) {
  final overlap = math.min(run.right, c.right) - math.max(run.left, c.left);
  final minWidth = math.min(_width(run), _width(c));
  if (overlap <= minWidth * 0.4) return false;
  final gap = run.bottom - c.top;
  return gap < math.min(_height(run), _height(c)) * 1.5;
}

HighlightRect _merge(HighlightRect a, HighlightRect b) => HighlightRect(
  left: math.min(a.left, b.left),
  top: math.max(a.top, b.top),
  right: math.max(a.right, b.right),
  bottom: math.min(a.bottom, b.bottom),
);
