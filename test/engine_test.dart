import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:microfs/src/data.dart';
import 'package:microfs/src/engine.dart';

import 'memory_file.dart';

/// Convenience: format a fresh engine backed by an in-memory file.
Future<MicroFsEngine> freshEngine() async {
  final raf = await tempMemoryFile();
  return MicroFsEngine.format(raf);
}

/// Convenience: write a UTF-8 string as file bytes.
Uint8List str(String s) {
  final bytes = <int>[];
  for (final c in s.codeUnits) {
    bytes.add(c);
  }
  return Uint8List.fromList(bytes);
}

/// Convenience: read file bytes back as a string.
String asStr(Uint8List b) => String.fromCharCodes(b);

void main() {
  // ── format + mount ──────────────────────────────────────────────────────────
  group('format + mount', () {
    test('format creates valid empty filesystem', () async {
      final engine = await freshEngine();
      expect(await engine.isDirectory('/'), isTrue);
      expect(await engine.listDirectory('/'), isEmpty);
    });

    test('mount reads an existing container', () async {
      final raf = await tempMemoryFile();
      await MicroFsEngine.format(raf);
      await MicroFsEngine.mount(raf); // should not throw
    });

    test('mount throws on invalid container', () async {
      final raf = await tempMemoryFile();
      // Write a data block marker at block 0 — invalid
      await raf.setPosition(0);
      await raf.writeByte(blockTypeData);
      expect(() => MicroFsEngine.mount(raf), throwsA(isA<Exception>()));
    });
  });

  // ── exists / isFile / isDirectory ──────────────────────────────────────────
  group('exists / isFile / isDirectory', () {
    test('root always exists and is a directory', () async {
      final engine = await freshEngine();
      expect(await engine.exists('/'), isTrue);
      expect(await engine.isDirectory('/'), isTrue);
      expect(await engine.isFile('/'), isFalse);
    });

    test('missing path returns false', () async {
      final engine = await freshEngine();
      expect(await engine.exists('/nope'), isFalse);
      expect(await engine.isFile('/nope'), isFalse);
      expect(await engine.isDirectory('/nope'), isFalse);
    });

    test('file is reported as file, not directory', () async {
      final engine = await freshEngine();
      await engine.writeFile('/f.txt', str('hi'));
      expect(await engine.isFile('/f.txt'), isTrue);
      expect(await engine.isDirectory('/f.txt'), isFalse);
    });

    test('directory is reported as directory, not file', () async {
      final engine = await freshEngine();
      await engine.createDirectory('/mydir');
      expect(await engine.isDirectory('/mydir'), isTrue);
      expect(await engine.isFile('/mydir'), isFalse);
    });
  });

  // ── write + read files ─────────────────────────────────────────────────────
  group('write + read file', () {
    test('small file round-trips', () async {
      final engine = await freshEngine();
      await engine.writeFile('/hello.txt', str('Hello, world!'));
      expect(asStr(await engine.readFile('/hello.txt')), 'Hello, world!');
    });

    test('empty file round-trips', () async {
      final engine = await freshEngine();
      await engine.writeFile('/empty.txt', Uint8List(0));
      expect(await engine.readFile('/empty.txt'), isEmpty);
    });

    test('exact 4095-byte file fits in one data block', () async {
      final engine = await freshEngine();
      final data = Uint8List(DataBlock.dataSize)..fillRange(0, DataBlock.dataSize, 0xAB);
      await engine.writeFile('/big.bin', data);
      final back = await engine.readFile('/big.bin');
      expect(back, data);
    });

    test('file just over 4095 bytes uses a blocklist', () async {
      final engine = await freshEngine();
      final data = Uint8List(DataBlock.dataSize + 1)..fillRange(0, DataBlock.dataSize + 1, 0x7F);
      await engine.writeFile('/over.bin', data);
      final back = await engine.readFile('/over.bin');
      expect(back, data);
    });

    test('large multi-block file round-trips', () async {
      final engine = await freshEngine();
      // 10 data blocks worth of data
      final data = Uint8List(DataBlock.dataSize * 10);
      for (int i = 0; i < data.length; i++) { data[i] = i % 251; }
      await engine.writeFile('/large.bin', data);
      final back = await engine.readFile('/large.bin');
      expect(back, data);
    });

    test('overwriting a file replaces content (hard delete)', () async {
      final engine = await freshEngine();
      await engine.writeFile('/f.txt', str('v1'));
      final usedAfterV1 = await engine.usedBlocks();
      await engine.writeFile('/f.txt', str('version two'));
      final usedAfterV2 = await engine.usedBlocks();
      // Block count should be the same (old blocks reclaimed)
      expect(usedAfterV2.length, usedAfterV1.length);
      expect(asStr(await engine.readFile('/f.txt')), 'version two');
    });

    test('fileSize returns correct value', () async {
      final engine = await freshEngine();
      await engine.writeFile('/s.txt', str('hello'));
      expect(await engine.fileSize('/s.txt'), 5);
    });

    test('read non-existent file throws', () async {
      final engine = await freshEngine();
      expect(() => engine.readFile('/nope'), throwsA(isA<Exception>()));
    });

    test('multiple independent files coexist', () async {
      final engine = await freshEngine();
      await engine.writeFile('/a.txt', str('alpha'));
      await engine.writeFile('/b.txt', str('beta'));
      await engine.writeFile('/c.txt', str('gamma'));
      expect(asStr(await engine.readFile('/a.txt')), 'alpha');
      expect(asStr(await engine.readFile('/b.txt')), 'beta');
      expect(asStr(await engine.readFile('/c.txt')), 'gamma');
    });
  });

  // ── delete file ────────────────────────────────────────────────────────────
  group('deleteFile', () {
    test('deleted file is no longer accessible', () async {
      final engine = await freshEngine();
      await engine.writeFile('/del.txt', str('bye'));
      await engine.deleteFile('/del.txt');
      expect(await engine.exists('/del.txt'), isFalse);
      expect(() => engine.readFile('/del.txt'), throwsA(isA<Exception>()));
    });

    test('deleting reclaims blocks (hard delete)', () async {
      final engine = await freshEngine();
      await engine.writeFile('/del.txt', str('data'));
      final before = await engine.usedBlocks();
      await engine.deleteFile('/del.txt');
      final after = await engine.usedBlocks();
      expect(after.length, lessThan(before.length));
    });

    test('deleting non-existent file throws', () async {
      final engine = await freshEngine();
      expect(() => engine.deleteFile('/nope'), throwsA(isA<Exception>()));
    });

    test('deleted slot is reused by next write', () async {
      final engine = await freshEngine();
      await engine.writeFile('/reuse.txt', str('first'));
      final usedAfterFirst = (await engine.usedBlocks()).length;
      await engine.deleteFile('/reuse.txt');
      await engine.writeFile('/reuse.txt', str('second'));
      final usedAfterSecond = (await engine.usedBlocks()).length;
      expect(usedAfterSecond, usedAfterFirst);
    });
  });

  // ── listDirectory ──────────────────────────────────────────────────────────
  group('listDirectory', () {
    test('empty root has no entries', () async {
      final engine = await freshEngine();
      expect(await engine.listDirectory('/'), isEmpty);
    });

    test('lists files and directories', () async {
      final engine = await freshEngine();
      await engine.writeFile('/a.txt', str('a'));
      await engine.createDirectory('/subdir');
      final entries = await engine.listDirectory('/');
      final names = entries.map((e) => e.name).toSet();
      expect(names, contains('a.txt'));
      expect(names, contains('subdir'));
    });

    test('deleted files do not appear in listing', () async {
      final engine = await freshEngine();
      await engine.writeFile('/gone.txt', str('x'));
      await engine.deleteFile('/gone.txt');
      final entries = await engine.listDirectory('/');
      expect(entries.map((e) => e.name), isNot(contains('gone.txt')));
    });

    test('listing non-existent directory throws', () async {
      final engine = await freshEngine();
      expect(() => engine.listDirectory('/nope'), throwsA(isA<Exception>()));
    });
  });

  // ── directories ────────────────────────────────────────────────────────────
  group('createDirectory', () {
    test('creates a subdirectory', () async {
      final engine = await freshEngine();
      await engine.createDirectory('/src');
      expect(await engine.isDirectory('/src'), isTrue);
    });

    test('creates nested directories with recursive=true', () async {
      final engine = await freshEngine();
      await engine.createDirectory('/a/b/c', recursive: true);
      expect(await engine.isDirectory('/a'), isTrue);
      expect(await engine.isDirectory('/a/b'), isTrue);
      expect(await engine.isDirectory('/a/b/c'), isTrue);
    });

    test('creating existing directory is idempotent', () async {
      final engine = await freshEngine();
      await engine.createDirectory('/dup');
      await engine.createDirectory('/dup'); // should not throw
    });

    test('non-recursive fails if parent missing', () async {
      final engine = await freshEngine();
      expect(
        () => engine.createDirectory('/missing/child'),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('deleteDirectory', () {
    test('deletes an empty directory', () async {
      final engine = await freshEngine();
      await engine.createDirectory('/empty');
      await engine.deleteDirectory('/empty');
      expect(await engine.exists('/empty'), isFalse);
    });

    test('non-recursive throws on non-empty directory', () async {
      final engine = await freshEngine();
      await engine.createDirectory('/nonempty');
      await engine.writeFile('/nonempty/f.txt', str('x'));
      expect(
        () => engine.deleteDirectory('/nonempty'),
        throwsA(isA<Exception>()),
      );
    });

    test('recursive deletes directory and all contents', () async {
      final engine = await freshEngine();
      await engine.createDirectory('/tree/a', recursive: true);
      await engine.writeFile('/tree/a/f.txt', str('hi'));
      await engine.writeFile('/tree/b.txt', str('bye'));
      await engine.deleteDirectory('/tree', recursive: true);
      expect(await engine.exists('/tree'), isFalse);
    });

    test('deleting root throws', () async {
      final engine = await freshEngine();
      expect(() => engine.deleteDirectory('/'), throwsA(isA<Exception>()));
    });
  });

  // ── files in subdirectories ─────────────────────────────────────────────────
  group('files in subdirectories', () {
    test('write and read file in subdirectory', () async {
      final engine = await freshEngine();
      await engine.createDirectory('/docs');
      await engine.writeFile('/docs/readme.txt', str('Read me!'));
      expect(asStr(await engine.readFile('/docs/readme.txt')), 'Read me!');
    });

    test('write with recursive creates parents', () async {
      final engine = await freshEngine();
      await engine.writeFile('/a/b/c.txt', str('deep'), recursive: true);
      expect(asStr(await engine.readFile('/a/b/c.txt')), 'deep');
    });

    test('files with same name in different directories are independent', () async {
      final engine = await freshEngine();
      await engine.createDirectory('/x');
      await engine.createDirectory('/y');
      await engine.writeFile('/x/f.txt', str('x'));
      await engine.writeFile('/y/f.txt', str('y'));
      expect(asStr(await engine.readFile('/x/f.txt')), 'x');
      expect(asStr(await engine.readFile('/y/f.txt')), 'y');
    });
  });

  // ── copy + rename ──────────────────────────────────────────────────────────
  group('copyFile', () {
    test('copy duplicates file content', () async {
      final engine = await freshEngine();
      await engine.writeFile('/orig.txt', str('original'));
      await engine.copyFile('/orig.txt', '/copy.txt');
      expect(asStr(await engine.readFile('/orig.txt')), 'original');
      expect(asStr(await engine.readFile('/copy.txt')), 'original');
    });

    test('modifying copy does not affect original', () async {
      final engine = await freshEngine();
      await engine.writeFile('/orig.txt', str('original'));
      await engine.copyFile('/orig.txt', '/copy.txt');
      await engine.writeFile('/copy.txt', str('modified'));
      expect(asStr(await engine.readFile('/orig.txt')), 'original');
    });
  });

  group('renameEntry', () {
    test('rename moves file', () async {
      final engine = await freshEngine();
      await engine.writeFile('/old.txt', str('data'));
      await engine.renameEntry('/old.txt', '/new.txt');
      expect(await engine.exists('/old.txt'), isFalse);
      expect(asStr(await engine.readFile('/new.txt')), 'data');
    });

    test('rename to same path is a no-op', () async {
      final engine = await freshEngine();
      await engine.writeFile('/a.txt', str('hello'));
      await engine.renameEntry('/a.txt', '/a.txt');
      expect(asStr(await engine.readFile('/a.txt')), 'hello');
    });

    test('rename replaces existing file', () async {
      final engine = await freshEngine();
      await engine.writeFile('/a.txt', str('source'));
      await engine.writeFile('/b.txt', str('old destination'));
      await engine.renameEntry('/a.txt', '/b.txt');
      expect(await engine.exists('/a.txt'), isFalse);
      expect(asStr(await engine.readFile('/b.txt')), 'source');
    });

    test('rename replacing file reclaims old destination blocks', () async {
      final engine = await freshEngine();
      await engine.writeFile('/a.txt', str('source'));
      await engine.writeFile('/b.txt', str('old destination'));
      final beforeBlocks = (await engine.usedBlocks()).length;
      await engine.renameEntry('/a.txt', '/b.txt');
      final afterBlocks = (await engine.usedBlocks()).length;
      // Old destination blocks freed, source blocks retained, so count drops.
      expect(afterBlocks, lessThan(beforeBlocks));
    });

    test('rename file over existing directory throws', () async {
      final engine = await freshEngine();
      await engine.writeFile('/f.txt', str('data'));
      await engine.createDirectory('/dir');
      expect(
        () => engine.renameEntry('/f.txt', '/dir'),
        throwsA(isA<Exception>()),
      );
    });

    test('rename file over existing link throws', () async {
      final engine = await freshEngine();
      await engine.writeFile('/f.txt', str('data'));
      await engine.createLink('/lnk', '/target');
      expect(
        () => engine.renameEntry('/f.txt', '/lnk'),
        throwsA(isA<Exception>()),
      );
    });

    test('rename directory', () async {
      final engine = await freshEngine();
      await engine.createDirectory('/olddir');
      await engine.writeFile('/olddir/f.txt', str('inside'));
      await engine.renameEntry('/olddir', '/newdir');
      expect(await engine.exists('/olddir'), isFalse);
      expect(await engine.isDirectory('/newdir'), isTrue);
      // Contents are accessible via new path
      expect(asStr(await engine.readFile('/newdir/f.txt')), 'inside');
    });
  });

  // ── directory chain extension ───────────────────────────────────────────────
  group('directory chain extension', () {
    test('more than 66 files in root triggers directory chain', () async {
      final engine = await freshEngine();
      // Write 70 files — more than 66 regular slots in one directory block
      for (int i = 0; i < 70; i++) {
        await engine.writeFile('/f$i.txt', str('content $i'));
      }
      final entries = await engine.listDirectory('/');
      expect(entries.length, 70);
    });

    test('all files readable after chain extension', () async {
      final engine = await freshEngine();
      for (int i = 0; i < 70; i++) {
        await engine.writeFile('/g$i.txt', str('value $i'));
      }
      for (int i = 0; i < 70; i++) {
        expect(asStr(await engine.readFile('/g$i.txt')), 'value $i');
      }
    });
  });

  // ── blocklist chaining ─────────────────────────────────────────────────────
  group('blocklist chaining', () {
    test('file requiring more than 1022 data blocks uses chained blocklists',
        () async {
      final engine = await freshEngine();
      // 1023 data blocks worth of data (one more than fits in a single BlockListBlock)
      final dataSize = DataBlock.dataSize * 1023;
      final data = Uint8List(dataSize);
      for (int i = 0; i < dataSize; i++) { data[i] = i % 199; }
      await engine.writeFile('/huge.bin', data);
      final back = await engine.readFile('/huge.bin');
      expect(back, data);
    });
  });

  // ── persistence across remount ─────────────────────────────────────────────
  group('persistence across remount', () {
    test('file survives remount', () async {
      final raf = await tempMemoryFile();
      final engine = await MicroFsEngine.format(raf);
      await engine.writeFile('/persist.txt', str('saved'));

      final remounted = await MicroFsEngine.mount(raf);
      expect(asStr(await remounted.readFile('/persist.txt')), 'saved');
    });

    test('directory structure survives remount', () async {
      final raf = await tempMemoryFile();
      final engine = await MicroFsEngine.format(raf);
      await engine.createDirectory('/docs');
      await engine.writeFile('/docs/note.txt', str('hello'));

      final remounted = await MicroFsEngine.mount(raf);
      expect(await remounted.isDirectory('/docs'), isTrue);
      expect(asStr(await remounted.readFile('/docs/note.txt')), 'hello');
    });

    test('delete persists across remount', () async {
      final raf = await tempMemoryFile();
      final engine = await MicroFsEngine.format(raf);
      await engine.writeFile('/temp.txt', str('x'));
      await engine.deleteFile('/temp.txt');

      final remounted = await MicroFsEngine.mount(raf);
      expect(await remounted.exists('/temp.txt'), isFalse);
    });
  });

  // ── usedBlocks / block accounting ──────────────────────────────────────────
  group('usedBlocks', () {
    test('fresh filesystem uses only block 0', () async {
      final engine = await freshEngine();
      expect(await engine.usedBlocks(), {0});
    });

    test('used block count grows with new files', () async {
      final engine = await freshEngine();
      final before = (await engine.usedBlocks()).length;
      await engine.writeFile('/f.txt', str('data'));
      final after = (await engine.usedBlocks()).length;
      expect(after, greaterThan(before));
    });
  });
  // ── symbolic links ─────────────────────────────────────────────────────────
  group('symbolic links', () {
    test('createLink + isLink + readLink', () async {
      final engine = await freshEngine();
      await engine.createLink('/mylink', '/target/path');
      expect(await engine.isLink('/mylink'), isTrue);
      expect(await engine.isFile('/mylink'), isFalse);
      expect(await engine.isDirectory('/mylink'), isFalse);
      expect(await engine.exists('/mylink'), isTrue);
      expect(await engine.readLink('/mylink'), '/target/path');
    });

    test('empty target round-trips', () async {
      final engine = await freshEngine();
      await engine.createLink('/empty', '');
      expect(await engine.readLink('/empty'), '');
    });

    test('link appears in listDirectory', () async {
      final engine = await freshEngine();
      await engine.writeFile('/file.txt', str('x'));
      await engine.createLink('/lnk', '/file.txt');
      final names = (await engine.listDirectory('/')).map((e) => e.name).toSet();
      expect(names, containsAll(['file.txt', 'lnk']));
    });

    test('readLink throws on non-link', () async {
      final engine = await freshEngine();
      await engine.writeFile('/f.txt', str('data'));
      expect(() => engine.readLink('/f.txt'), throwsA(isA<Exception>()));
    });

    test('createLink throws if path already exists', () async {
      final engine = await freshEngine();
      await engine.createLink('/dup', '/a');
      expect(() => engine.createLink('/dup', '/b'), throwsA(isA<Exception>()));
    });

    test('deleteLink removes link and reclaims blocks', () async {
      final engine = await freshEngine();
      await engine.createLink('/gone', '/wherever');
      final before = (await engine.usedBlocks()).length;
      await engine.deleteLink('/gone');
      final after = (await engine.usedBlocks()).length;
      expect(await engine.exists('/gone'), isFalse);
      expect(after, lessThan(before));
    });

    test('deleteLink throws on non-link', () async {
      final engine = await freshEngine();
      await engine.writeFile('/f.txt', str('x'));
      expect(() => engine.deleteLink('/f.txt'), throwsA(isA<Exception>()));
    });

    test('updateLink changes target', () async {
      final engine = await freshEngine();
      await engine.createLink('/lnk', '/old');
      await engine.updateLink('/lnk', '/new');
      expect(await engine.readLink('/lnk'), '/new');
    });

    test('updateLink reclaims old target blocks', () async {
      final engine = await freshEngine();
      await engine.createLink('/lnk', '/old');
      final before = (await engine.usedBlocks()).length;
      await engine.updateLink('/lnk', '/new');
      final after = (await engine.usedBlocks()).length;
      expect(after, equals(before));
    });

    test('renameEntry works for links', () async {
      final engine = await freshEngine();
      await engine.createLink('/a', '/target');
      await engine.renameEntry('/a', '/b');
      expect(await engine.exists('/a'), isFalse);
      expect(await engine.isLink('/b'), isTrue);
      expect(await engine.readLink('/b'), '/target');
    });

    test('link survives remount', () async {
      final raf = await tempMemoryFile();
      final engine = await MicroFsEngine.format(raf);
      await engine.createLink('/lnk', '/some/path');
      final remounted = await MicroFsEngine.mount(raf);
      expect(await remounted.isLink('/lnk'), isTrue);
      expect(await remounted.readLink('/lnk'), '/some/path');
    });

    test('recursive deleteDirectory removes links', () async {
      final engine = await freshEngine();
      await engine.createDirectory('/dir');
      await engine.createLink('/dir/lnk', '/target');
      await engine.deleteDirectory('/dir', recursive: true);
      expect(await engine.exists('/dir'), isFalse);
    });

    test('long link target (near DataBlock.dataSize) stays in single block', () async {
      final engine = await freshEngine();
      final longTarget = '/${'a' * (DataBlock.dataSize - 1)}';
      await engine.createLink('/long', longTarget);
      expect(await engine.readLink('/long'), longTarget);
    });

    test('link blocks are accounted in usedBlocks', () async {
      final engine = await freshEngine();
      final before = (await engine.usedBlocks()).length;
      await engine.createLink('/lnk', '/x');
      final after = (await engine.usedBlocks()).length;
      expect(after, greaterThan(before));
    });
  });
}
