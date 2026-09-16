import 'package:flutter/material.dart';

import '../../../domain/entities/entities.dart';

/// Marker colours (FR-90).
const pdfMarkerColors = {
  HighlightColor.yellow: Color(0xFFFFE066),
  HighlightColor.green: Color(0xFF8CE99A),
  HighlightColor.blue: Color(0xFF74C0FC),
  HighlightColor.pink: Color(0xFFFFA8C5),
};

/// Menu shown when text is selected in the PDF viewer.
///
/// pdfrx builds its default menu with `AdaptiveTextSelectionToolbar`, which
/// looks up `MaterialLocalizations` from inside the viewer's own stack and
/// throws there. This menu carries its own labels and uses no widget that
/// needs localizations, so it builds wherever the viewer is placed.
class PdfSelectionMenu extends StatelessWidget {
  const PdfSelectionMenu({
    super.key,
    required this.copyLabel,
    required this.markerLabel,
    required this.askAiLabel,
    required this.onCopy,
    required this.onAskAi,
    required this.onHighlight,
  });

  final String copyLabel;
  final String markerLabel;
  final String askAiLabel;
  final VoidCallback onCopy;
  final VoidCallback onAskAi;
  final ValueChanged<HighlightColor> onHighlight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 6,
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _Action(icon: Icons.copy, label: copyLabel, onTap: onCopy),
                _Action(
                  icon: Icons.auto_awesome_outlined,
                  label: askAiLabel,
                  onTap: onAskAi,
                ),
              ],
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(
                    Icons.format_color_text,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                Text(markerLabel, style: TextStyle(color: scheme.onSurface)),
                const SizedBox(width: 4),
                for (final c in HighlightColor.values)
                  InkWell(
                    key: Key('marker-${c.name}'),
                    onTap: () => onHighlight(c),
                    borderRadius: BorderRadius.circular(20),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          color: pdfMarkerColors[c],
                          shape: BoxShape.circle,
                          border: Border.all(color: scheme.outlineVariant),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(color: scheme.onSurface)),
          ],
        ),
      ),
    );
  }
}
