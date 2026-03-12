import 'dart:io' show FileMode;

import 'package:file/local.dart';
import 'package:microfs/microfs.dart';

void main() async {
  final localFs = LocalFileSystem();
  final tempDir = await localFs.systemTempDirectory.createTemp('microfs_');
  final containerFile = tempDir.childFile('container.bin');

  // --- Format a new container -------------------------------------------
  final formatRaf = await containerFile.open(mode: FileMode.write);
  final fs = await MicroFileSystem.format(formatRaf);

  // Write some files and create a subdirectory
  await fs.file('/hello.txt').writeAsString('Hello, microfs!');
  await fs.file('/data.bin').writeAsBytes([1, 2, 3, 4, 5]);
  await fs.directory('/docs').create();
  await fs.file('/docs/readme.txt').writeAsString('Welcome to microfs v2.');

  print('Written entries:');
  await for (final entity in fs.directory('/').list()) {
    print('  ${entity.path}');
  }

  await formatRaf.close();

  // --- Mount the existing container -------------------------------------
  // Read bytes and reopen for read-write access without truncation.
  final bytes = await containerFile.readAsBytes();
  final mountRaf = await containerFile.open(mode: FileMode.write);
  await mountRaf.writeFrom(bytes);

  final fs2 = await MicroFileSystem.mount(mountRaf);

  print('\nAfter re-mount:');
  print('  hello.txt: ${await fs2.file('/hello.txt').readAsString()}');
  print('  data.bin:  ${await fs2.file('/data.bin').readAsBytes()}');
  print('  docs/readme.txt: ${await fs2.file('/docs/readme.txt').readAsString()}');

  await mountRaf.close();
  await tempDir.delete(recursive: true);
}
