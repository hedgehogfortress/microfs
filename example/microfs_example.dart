import 'dart:io' show FileMode;

import 'package:file/local.dart';
import 'package:microfs/microfs.dart';

void main() async {
  final localFs = LocalFileSystem();
  final tempDir = await localFs.systemTempDirectory.createTemp('microfs_');
  final containerFile = tempDir.childFile('container.bin');

  // --- Format a new container -------------------------------------------
  final formatRaf = await containerFile.open(mode: FileMode.write);
  final fs = await MicroFileSystem.format(
    formatRaf,
    blockSize: 4096,
    maxBlocksPerFile: 8,
  );

  // Write some files
  await fs.file('hello.txt').writeAsString('Hello, microfs!');
  await fs.file('data.bin').writeAsBytes([1, 2, 3, 4, 5]);

  print('Written files:');
  await for (final entity in fs.currentDirectory.list()) {
    print('  ${entity.path}');
  }

  await formatRaf.close();

  // --- Mount the existing container -------------------------------------
  final mountRaf = await containerFile.open();
  final fs2 = await MicroFileSystem.mount(mountRaf);

  print('\nAfter re-mount:');
  print('  hello.txt: ${await fs2.file('hello.txt').readAsString()}');
  print('  data.bin:  ${await fs2.file('data.bin').readAsBytes()}');

  await mountRaf.close();
  await tempDir.delete(recursive: true);
}
