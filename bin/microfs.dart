import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file/file.dart' as pf;
import 'package:file/local.dart';
import 'package:microfs/microfs.dart';

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
    fs = await MicroFileSystem.format(raf);
    stdout.writeln('Formatted $path.');
  } else {
    if (!await containerFile.exists()) {
      stderr.writeln('Error: $path does not exist. Use --fmt to create and format it.');
      exitCode = 1;
      return;
    }
    final raf = await _openReadWrite(containerFile);
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

/// Opens [f] for random read-write access without truncating existing content.
/// Reads the bytes first, reopens with [FileMode.write] (which truncates),
/// then restores the content so the engine can seek and overwrite freely.
Future<RandomAccessFile> _openReadWrite(File f) async {
  final bytes = await f.readAsBytes();
  final raf = await f.open(mode: FileMode.write);
  if (bytes.isNotEmpty) await raf.writeFrom(bytes);
  return raf;
}

Future<void> _runShell(MicroFileSystem fs) async {
  while (true) {
    stdout.write('microfs> ');
    final line = stdin.readLineSync();
    if (line == null) break;

    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;

    final echoAppend = RegExp(r'^echo\s+(.*?)\s*>>\s*(\S+)$').firstMatch(trimmed);
    final echoWrite = RegExp(r'^echo\s+(.*?)\s*>\s*(\S+)$').firstMatch(trimmed);
    if (echoAppend != null) {
      await _echo(fs, echoAppend.group(1)!, echoAppend.group(2)!, append: true);
      continue;
    }
    if (echoWrite != null) {
      await _echo(fs, echoWrite.group(1)!, echoWrite.group(2)!, append: false);
      continue;
    }

    final parts = trimmed.split(RegExp(r'\s+'));

    switch (parts.first) {
      case 'ls':
        await _ls(fs);
      case 'cat':
        if (parts.length < 2) {
          stderr.writeln('Usage: cat <filename>');
        } else {
          await _cat(fs, parts[1]);
        }
      case 'touch':
        if (parts.length < 2) {
          stderr.writeln('Usage: touch <filename>');
        } else {
          await _touch(fs, parts[1]);
        }
      case 'rm':
        if (parts.length < 2) {
          stderr.writeln('Usage: rm <filename>');
        } else {
          await _rm(fs, parts[1]);
        }
      case 'echo':
        stdout.writeln(parts.skip(1).join(' '));
      case 'help':
        stdout.writeln('  ls                         list files');
        stdout.writeln('  cat <file>                 print file contents');
        stdout.writeln('  touch <file>               create an empty file');
        stdout.writeln('  rm <file>                  delete a file');
        stdout.writeln('  echo <text> > <file>       write text to a file');
        stdout.writeln('  echo <text> >> <file>      append text to a file');
        stdout.writeln('  exit                       quit');
      case 'exit' || 'quit':
        return;
      default:
        stderr.writeln('Unknown command: ${parts.first}. Type "help" for commands.');
    }
  }
}

Future<void> _ls(MicroFileSystem fs) async {
  final entities = await fs.directory('/').list().toList();
  if (entities.isEmpty) {
    stdout.writeln('(empty)');
    return;
  }
  for (final entity in entities) {
    final name = entity.basename;
    if (entity is pf.File) {
      final size = await entity.length();
      stdout.writeln('${name.padRight(48)}$size');
    } else if (entity is pf.Directory) {
      stdout.writeln('${name.padRight(48)}<dir>');
    } else {
      stdout.writeln('${name.padRight(48)}<link>');
    }
  }
}

Future<void> _cat(MicroFileSystem fs, String filename) async {
  try {
    final bytes = await fs.file('/$filename').readAsBytes();
    stdout.write(utf8.decode(bytes, allowMalformed: true));
    if (bytes.isNotEmpty && bytes.last != 0x0A) stdout.writeln();
  } on FileSystemException {
    stderr.writeln('cat: $filename: No such file');
  }
}

Future<void> _touch(MicroFileSystem fs, String filename) async {
  try {
    await fs.file('/$filename').create();
  } on FileSystemException catch (e) {
    stderr.writeln('touch: $filename: ${e.message}');
  }
}

Future<void> _rm(MicroFileSystem fs, String filename) async {
  try {
    await fs.file('/$filename').delete();
  } on FileSystemException {
    stderr.writeln('rm: $filename: No such file');
  }
}

Future<void> _echo(
  MicroFileSystem fs,
  String text,
  String filename, {
  required bool append,
}) async {
  final newBytes = Uint8List.fromList(utf8.encode('$text\n'));
  try {
    final f = fs.file('/$filename');
    if (append && await f.exists()) {
      await f.writeAsBytes(newBytes, mode: FileMode.append);
    } else {
      await f.writeAsBytes(newBytes);
    }
  } on FileSystemException catch (e) {
    stderr.writeln('echo: $filename: ${e.message}');
  }
}
