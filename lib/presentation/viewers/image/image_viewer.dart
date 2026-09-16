import 'package:flutter/material.dart';

import '../../../domain/entities/entities.dart';
import '../common/sandboxed_html_view.dart';

class ImageViewer extends StatelessWidget {
  const ImageViewer({super.key, required this.file});

  final FileContent file;

  @override
  Widget build(BuildContext context) {
    if (file.path.toLowerCase().endsWith('.svg')) {
      return Padding(
        padding: const EdgeInsets.all(8),
        child: SandboxedHtmlView(
          html: file.text ?? '',
          initiallyExpanded: true,
        ),
      );
    }
    return InteractiveViewer(
      maxScale: 8,
      child: Center(
        child: Image.memory(
          file.bytes,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) =>
              const Icon(Icons.broken_image_outlined, size: 48),
        ),
      ),
    );
  }
}
