import 'dart:io';

import 'package:file/memory.dart';

Future<RandomAccessFile> tempMemoryFile() async {
  final fs = MemoryFileSystem();
  final dir = await fs.systemTempDirectory.createTemp("tmp");
  final file = dir.childFile("file");
  return await file.open(mode: FileMode.write);
}
