import 'dart:convert';
import 'dart:io';

import 'package:file/local.dart';
import 'package:microfs/microfs.dart';

const _blockSize = 4096;
const _maxBlocksPerFile = 64;

void main(List<String> args) async {
  final fmt = args.contains('--fmt');
  final positional = args.where((a) => !a.startsWith('-')).toList();

  if (positional.isEmpty) {
    stderr.writeln('Usage: microfs [--fmt] <container-path>');
    exitCode = 1;
    return;
  }

  final path = positional.first;
  final containerFile = LocalFileSystem().file(path);

  MicroFileSystem fs;

  if (fmt) {
    final exists = await containerFile.exists();
    final prompt = exists
        ? 'Format $path? This will erase all existing data. [y/N] '
        : 'Container $path does not exist. Create and format it? [y/N] ';
    stdout.write(prompt);
    final answer = stdin.readLineSync() ?? '';
    if (answer.trim().toLowerCase() != 'y') {
      stderr.writeln('Aborted.');
      exitCode = 1;
      return;
    }
    final raf = await containerFile.open(mode: FileMode.write);
    fs = await MicroFileSystem.format(
      raf,
      blockSize: _blockSize,
      maxBlocksPerFile: _maxBlocksPerFile,
    );
    stdout.writeln('Formatted $path.');
  } else {
    if (!await containerFile.exists()) {
      stderr.writeln('Error: $path does not exist. Use --fmt to create and format it.');
      exitCode = 1;
      return;
    }
    final raf = await containerFile.open();
    try {
      fs = await MicroFileSystem.mount(raf);
    } catch (e) {
      stderr.writeln('Error: $path is not a valid microfs container.');
      exitCode = 1;
      return;
    }
  }

  stdout.writeln('Mounted $path. Type "help" for commands.');
  await _runShell(fs);
}

Future<void> _runShell(MicroFileSystem fs) async {
  while (true) {
    stdout.write('microfs> ');
    final line = stdin.readLineSync();
    if (line == null) break; // EOF

    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) continue;

    switch (parts.first) {
      case 'ls':
        await _ls(fs);
      case 'cat':
        if (parts.length < 2) {
          stderr.writeln('Usage: cat <filename>');
        } else {
          await _cat(fs, parts[1]);
        }
      case 'help':
        stdout.writeln('  ls              list files');
        stdout.writeln('  cat <filename>  print file contents');
        stdout.writeln('  exit            quit');
      case 'exit' || 'quit':
        return;
      default:
        stderr.writeln('Unknown command: ${parts.first}. Type "help" for commands.');
    }
  }
}

Future<void> _ls(MicroFileSystem fs) async {
  final files = await fs.listFiles();
  if (files.isEmpty) {
    stdout.writeln('(empty)');
    return;
  }
  for (final name in files) {
    final size = await fs.fileSize(name);
    stdout.writeln('${name.padRight(48)}$size');
  }
}

Future<void> _cat(MicroFileSystem fs, String filename) async {
  try {
    final bytes = await fs.readFile(filename);
    stdout.write(utf8.decode(bytes, allowMalformed: true));
    // Ensure output ends with a newline if the file doesn't.
    if (bytes.isNotEmpty && bytes.last != 0x0A) stdout.writeln();
  } on FileSystemException {
    stderr.writeln('cat: $filename: No such file');
  }
}
