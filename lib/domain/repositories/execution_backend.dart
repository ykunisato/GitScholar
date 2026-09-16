import 'dart:typed_data';

/// Output produced while executing code (Jupyter iopub messages).
sealed class ExecOutput {
  const ExecOutput();
}

class ExecStream extends ExecOutput {
  const ExecStream(this.name, this.text);
  final String name;
  final String text;
}

class ExecDisplay extends ExecOutput {
  const ExecDisplay(
    this.data, {
    this.metadata = const {},
    this.isResult = false,
    this.executionCount,
  });
  final Map<String, dynamic> data;
  final Map<String, dynamic> metadata;
  final bool isResult;
  final int? executionCount;
}

class ExecError extends ExecOutput {
  const ExecError(this.ename, this.evalue, this.traceback);
  final String ename;
  final String evalue;
  final List<String> traceback;
}

class ExecInput extends ExecOutput {
  const ExecInput(this.executionCount);
  final int executionCount;
}

/// Kernel spec summary.
class KernelSpecInfo {
  const KernelSpecInfo({
    required this.name,
    required this.displayName,
    required this.language,
  });
  final String name;
  final String displayName;
  final String language;
}

/// Remote execution environment (ADR-0006).
abstract class ExecutionBackend {
  /// Server version string; throws on connection or auth failure.
  Future<String> status();
  Future<List<KernelSpecInfo>> kernelSpecs();
  Future<String> startKernel(String name);
  Stream<ExecOutput> execute(String kernelId, String code);
  Future<void> interrupt(String kernelId);
  Future<void> restart(String kernelId);
  Future<void> shutdown(String kernelId);
  Future<void> uploadFile(String path, Uint8List bytes);
  Future<Uint8List> downloadFile(String path);
}
