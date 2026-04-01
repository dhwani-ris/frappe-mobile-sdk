import 'dart:io';

import 'package:image/image.dart' as img;

Future<void> main() async {
  final repoRoot = Directory.current.parent.path; // example/.. -> repo root
  final sourcePath = '$repoRoot/logo.png';
  final sourceFile = File(sourcePath);
  if (!await sourceFile.exists()) {
    stderr.writeln('Source icon not found: $sourcePath');
    exitCode = 2;
    return;
  }

  final bytes = await sourceFile.readAsBytes();
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    stderr.writeln('Failed to decode PNG: $sourcePath');
    exitCode = 3;
    return;
  }

  // Android launcher icon sizes (legacy mipmap icons).
  const sizes = <String, int>{
    'mipmap-mdpi': 48,
    'mipmap-hdpi': 72,
    'mipmap-xhdpi': 96,
    'mipmap-xxhdpi': 144,
    'mipmap-xxxhdpi': 192,
  };

  final resDir = Directory('android/app/src/main/res');
  for (final entry in sizes.entries) {
    final dir = Directory('${resDir.path}/${entry.key}');
    await dir.create(recursive: true);

    final resized = img.copyResize(
      decoded,
      width: entry.value,
      height: entry.value,
      interpolation: img.Interpolation.average,
    );

    final outFile = File('${dir.path}/ic_launcher.png');
    await outFile.writeAsBytes(img.encodePng(resized, level: 6));
    stdout.writeln('Wrote ${outFile.path}');
  }
}
