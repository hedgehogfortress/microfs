import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;

    // Parse echo redirections before splitting on whitespace.
    // Supports:  echo <text> >  <file>   (overwrite)
    //            echo <text> >> <file>   (append)
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
        // echo without redirection — print to stdout like a normal shell.
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
    if (bytes.isNotEmpty && bytes.last != 0x0A) stdout.writeln();
  } on FileSystemException {
    stderr.writeln('cat: $filename: No such file');
  }
}

Future<void> _touch(MicroFileSystem fs, String filename) async {
  if (!await fs.fileExists(filename)) {
    await fs.writeFile(filename, Uint8List(0));
  }
}

Future<void> _rm(MicroFileSystem fs, String filename) async {
  try {
    await fs.deleteFile(filename);
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
  final newBytes = utf8.encode('$text\n');
  final Uint8List data;
  if (append && await fs.fileExists(filename)) {
    final existing = await fs.readFile(filename);
    data = Uint8List.fromList([...existing, ...newBytes]);
  } else {
    data = Uint8List.fromList(newBytes);
  }
  try {
    await fs.writeFile(filename, data);
  } on FileSystemException catch (e) {
    stderr.writeln('echo: $filename: ${e.message}');
  }
}

