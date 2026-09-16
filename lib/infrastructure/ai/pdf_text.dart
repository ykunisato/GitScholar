import 'dart:typed_data';

import 'package:pdfrx/pdfrx.dart';

/// Extracts text per page with pdfrx (docs/05_viewers.md §1).
Future<List<String>> extractPdfText(List<int> bytes) async {
  final doc = await PdfDocument.openData(Uint8List.fromList(bytes));
  try {
    final pages = <String>[];
    for (final page in doc.pages) {
      final text = await page.loadStructuredText();
      pages.add(text.fullText);
    }
    return pages;
  } finally {
    await doc.dispose();
  }
}
