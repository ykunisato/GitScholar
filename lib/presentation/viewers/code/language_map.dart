import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/ini.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/julia.dart';
import 'package:re_highlight/languages/latex.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/plaintext.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/r.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart';

import '../../../domain/services/file_kind_detector.dart';

/// Highlight language id and mode for a file path (docs/05 §4).
(String, Mode) languageForPath(String path) =>
    languageForName(FileKindDetector.extension(path));

/// Highlight language for an extension or notebook language name.
(String, Mode) languageForName(String name) => switch (name.toLowerCase()) {
  'py' || 'python' || 'ipython' || 'ipython3' => ('python', langPython),
  'r' => ('r', langR),
  'jl' || 'julia' => ('julia', langJulia),
  'sh' || 'bash' || 'shell' || 'zsh' => ('bash', langBash),
  'js' || 'javascript' => ('javascript', langJavascript),
  'ts' || 'typescript' => ('typescript', langTypescript),
  'dart' => ('dart', langDart),
  'c' || 'cpp' || 'h' || 'stan' || 'c++' => ('cpp', langCpp),
  'java' => ('java', langJava),
  'sql' => ('sql', langSql),
  'yaml' || 'yml' => ('yaml', langYaml),
  'json' || 'ipynb' => ('json', langJson),
  'toml' || 'ini' || 'cfg' => ('ini', langIni),
  'tex' || 'latex' || 'bib' => ('latex', langLatex),
  'md' || 'markdown' || 'qmd' || 'rmd' => ('markdown', langMarkdown),
  'xml' || 'html' || 'svg' => ('xml', langXml),
  _ => ('plaintext', langPlaintext),
};
