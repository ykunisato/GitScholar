import 'dart:io';

/// Fails when line coverage in an lcov file is below the threshold.
/// Usage: dart run tool/check_coverage.dart coverage/lcov.info 80
void main(List<String> args) {
  final file = File(args[0]);
  final threshold = double.parse(args.length > 1 ? args[1] : '80');
  var found = 0;
  var hit = 0;
  for (final line in file.readAsLinesSync()) {
    if (line.startsWith('LF:')) found += int.parse(line.substring(3));
    if (line.startsWith('LH:')) hit += int.parse(line.substring(3));
  }
  final pct = found == 0 ? 100.0 : hit * 100 / found;
  stdout.writeln('Line coverage: ${pct.toStringAsFixed(1)}% ($hit/$found)');
  if (pct < threshold) {
    stderr.writeln('Coverage below $threshold%');
    exit(1);
  }
}
