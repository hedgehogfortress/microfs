import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:microfs/microfs.dart';
import 'package:microfs/src/data.dart';
import 'memory_file.dart';

void main() {
  // Compact super for chain extension tests: 128-byte blocks, max 4 blocks per file.
  // entriesCapacity = (128 - 8) ~/ (48 + 13 + 4*4) = 120 ~/ 77 = 1
  // So a 128-byte block holds exactly 1 directory entry (useful for chain tests).
  const smallSuper = Super(blockSize: 128, maxBlocksPerFile: 4);

  // Larger super used for most non-chain tests: 4096-byte blocks, 8 per file.
  // entriesCapacity = (4096 - 8) ~/ (48 + 13 + 8*4) = 4088 ~/ 93 = 43
  const stdSuper = Super(blockSize: 4096, maxBlocksPerFile: 8);

  Future<MicroFileSystem> formatWith(RandomAccessFile raf, Super s) =>
      MicroFileSystem.format(raf, blockSize: s.blockSize, maxBlocksPerFile: s.maxBlocksPerFile);

  // ---------------------------------------------------------------------------
  // Serialisation round-trips
  // ---------------------------------------------------------------------------
  group('Serialisation', () {
    test('Super toBytes / fromBytes round-trip', () {
      const s = Super(blockSize: 1024, maxBlocksPerFile: 16);
      final bytes = s.toBytes();
      expect(bytes.length, equals(Super.byteSize));
      final s2 = Super.fromBytes(bytes);
      expect(s2.blockSize, equals(s.blockSize));
      expect(s2.maxBlocksPerFile, equals(s.maxBlocksPerFile));
      expect(s2.maxFileSize, equals(s.maxFileSize));
    });

    test('DirectoryEntry toBytes / fromBytes round-trip', () {
      const s = stdSuper;
      final entry = DirectoryEntry(
        filename: 'README.TXT',
        deleted: false,
        fileId: 42,
        size: 12345,
        blockIndices: [3, 7, 0, 0, 0, 0, 0, 0],
      );
      final bytes = entry.toBytes(s);
      expect(bytes.length, equals(DirectoryEntry.fixedByteSize(s)));
      final e2 = DirectoryEntry.fromBytes(bytes, s);
      expect(e2.filename, equals(entry.filename));
      expect(e2.deleted, isFalse);
      expect(e2.fileId, equals(42));
      expect(e2.size, equals(12345));
      expect(e2.blockIndices, equals(entry.blockIndices));
    });

    test('DirectoryEntry deleted flag survives round-trip', () {
      const s = stdSuper;
      final entry = DirectoryEntry(
        filename: 'OLD.DAT',
        deleted: true,
        fileId: 1,
        size: 0,
        blockIndices: List.filled(s.maxBlocksPerFile, 0),
      );
      final e2 = DirectoryEntry.fromBytes(entry.toBytes(s), s);
      expect(e2.deleted, isTrue);
    });

    test('Meta toBytes / fromBytes round-trip', () {
      const s = stdSuper;
      final original = Meta.empty(s);
      final bytes = original.toBytes(s);
      expect(bytes.length, equals(s.blockSize));
      final m2 = Meta.fromBytes(bytes, s);
      expect(m2.nextMetaOffset, isNull);
      expect(m2.entries.length, equals(Meta.entriesCapacity(s)));
    });

    test('Meta nextMetaOffset persists across round-trip', () {
      const s = stdSuper;
      final meta = Meta(
        nextMetaOffset: 7,
        entries: List.generate(
          Meta.entriesCapacity(s),
          (_) => DirectoryEntry.empty(s),
          growable: false,
        ),
      );
      final m2 = Meta.fromBytes(meta.toBytes(s), s);
      expect(m2.nextMetaOffset, equals(7));
    });
  });

  // ---------------------------------------------------------------------------
  // format + mount basics
  // ---------------------------------------------------------------------------
  group('format + mount', () {
    test('format produces a filesystem with empty file listing', () async {
      final raf = await tempMemoryFile();
      final fs = await formatWith(raf, stdSuper);
      expect(await fs.listFiles(), isEmpty);
    });

    test('mount reads the same Super fields written by format', () async {
      final raf = await tempMemoryFile();
      await formatWith(raf, stdSuper);
      final fs = await MicroFileSystem.mount(raf);
      // Access super indirectly via maxFileSize
      expect(await fs.listFiles(), isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // Core file operations
  // ---------------------------------------------------------------------------
  group('Core file operations', () {
    late RandomAccessFile raf;
    late MicroFileSystem fs;

    setUp(() async {
      raf = await tempMemoryFile();
      fs = await formatWith(raf, stdSuper);
    });

    test('write then read returns identical bytes', () async {
      final data = Uint8List.fromList(List.generate(256, (i) => i & 0xFF));
      await fs.writeFile('DATA.BIN', data);
      expect(await fs.readFile('DATA.BIN'), equals(data));
    });

    test('fileExists returns true after write, false before', () async {
      expect(await fs.fileExists('MISSING.TXT'), isFalse);
      await fs.writeFile('PRESENT.TXT', Uint8List.fromList([1, 2, 3]));
      expect(await fs.fileExists('PRESENT.TXT'), isTrue);
    });

    test('fileSize returns correct byte count', () async {
      final data = Uint8List(999);
      await fs.writeFile('BIG.DAT', data);
      expect(await fs.fileSize('BIG.DAT'), equals(999));
    });

    test('write empty file', () async {
      await fs.writeFile('EMPTY.TXT', Uint8List(0));
      expect(await fs.fileExists('EMPTY.TXT'), isTrue);
      expect(await fs.fileSize('EMPTY.TXT'), equals(0));
      expect(await fs.readFile('EMPTY.TXT'), isEmpty);
    });

    test('overwrite replaces content; listFiles has one entry', () async {
      await fs.writeFile('FILE.TXT', Uint8List.fromList([1, 2, 3]));
      await fs.writeFile('FILE.TXT', Uint8List.fromList([9, 8, 7, 6]));
      final result = await fs.readFile('FILE.TXT');
      expect(result, equals(Uint8List.fromList([9, 8, 7, 6])));
      final files = await fs.listFiles();
      expect(files.where((f) => f == 'FILE.TXT').length, equals(1));
    });

    test('delete makes fileExists return false', () async {
      await fs.writeFile('GONE.TXT', Uint8List.fromList([42]));
      await fs.deleteFile('GONE.TXT');
      expect(await fs.fileExists('GONE.TXT'), isFalse);
      expect(await fs.listFiles(), isEmpty);
    });

    test('delete non-existent file throws FileSystemException', () async {
      expect(
        () => fs.deleteFile('NOPE.TXT'),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('read non-existent file throws FileSystemException', () async {
      expect(
        () => fs.readFile('NOPE.TXT'),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('listFiles returns only live (non-deleted) files', () async {
      await fs.writeFile('A.TXT', Uint8List.fromList([1]));
      await fs.writeFile('B.TXT', Uint8List.fromList([2]));
      await fs.writeFile('C.TXT', Uint8List.fromList([3]));
      await fs.deleteFile('B.TXT');
      final files = await fs.listFiles();
      expect(files, containsAll(['A.TXT', 'C.TXT']));
      expect(files, isNot(contains('B.TXT')));
    });

    test('multiple independent files coexist', () async {
      await fs.writeFile('ONE.TXT', Uint8List.fromList([1]));
      await fs.writeFile('TWO.TXT', Uint8List.fromList([2, 2]));
      await fs.writeFile('THREE.TXT', Uint8List.fromList([3, 3, 3]));
      expect(await fs.readFile('ONE.TXT'), equals(Uint8List.fromList([1])));
      expect(
        await fs.readFile('TWO.TXT'),
        equals(Uint8List.fromList([2, 2])),
      );
      expect(
        await fs.readFile('THREE.TXT'),
        equals(Uint8List.fromList([3, 3, 3])),
      );
    });

    test('multi-block file is written and read correctly', () async {
      // Write a file larger than one block (stdSuper.blockSize = 4096).
      final data = Uint8List.fromList(
        List.generate(stdSuper.blockSize * 3 + 17, (i) => i & 0xFF),
      );
      await fs.writeFile('LARGE.BIN', data);
      expect(await fs.readFile('LARGE.BIN'), equals(data));
    });
  });

  // ---------------------------------------------------------------------------
  // Persistence: close (RAF stays open in-memory) then re-mount
  // ---------------------------------------------------------------------------
  group('Persistence across re-mount', () {
    test('written data survives a re-mount', () async {
      final raf = await tempMemoryFile();
      final fs1 = await formatWith(raf, stdSuper);
      final payload = Uint8List.fromList('Hello, persistent world!'.codeUnits);
      await fs1.writeFile('HELLO.TXT', payload);

      // Re-mount on the same RandomAccessFile (simulates reopen).
      final fs2 = await MicroFileSystem.mount(raf);
      expect(await fs2.readFile('HELLO.TXT'), equals(payload));
    });

    test('overwrite persists across re-mount', () async {
      final raf = await tempMemoryFile();
      final fs1 = await formatWith(raf, stdSuper);
      await fs1.writeFile('FILE.TXT', Uint8List.fromList([1, 2, 3]));
      await fs1.writeFile('FILE.TXT', Uint8List.fromList([9, 8]));

      final fs2 = await MicroFileSystem.mount(raf);
      expect(
        await fs2.readFile('FILE.TXT'),
        equals(Uint8List.fromList([9, 8])),
      );
    });

    test('delete persists across re-mount', () async {
      final raf = await tempMemoryFile();
      final fs1 = await formatWith(raf, stdSuper);
      await fs1.writeFile('TEMP.TXT', Uint8List.fromList([0]));
      await fs1.deleteFile('TEMP.TXT');

      final fs2 = await MicroFileSystem.mount(raf);
      expect(await fs2.listFiles(), isEmpty);
      expect(await fs2.fileExists('TEMP.TXT'), isFalse);
    });

    test('multiple files all survive re-mount', () async {
      final raf = await tempMemoryFile();
      final fs1 = await formatWith(raf, stdSuper);
      for (var i = 0; i < 5; i++) {
        await fs1.writeFile(
          'FILE$i.DAT',
          Uint8List.fromList([i, i + 1, i + 2]),
        );
      }

      final fs2 = await MicroFileSystem.mount(raf);
      for (var i = 0; i < 5; i++) {
        expect(
          await fs2.readFile('FILE$i.DAT'),
          equals(Uint8List.fromList([i, i + 1, i + 2])),
        );
      }
    });
  });

  // ---------------------------------------------------------------------------
  // Meta chain extension
  // ---------------------------------------------------------------------------
  group('Meta chain extension', () {
    // smallSuper has capacity = 1 entry per Meta block, so adding a 2nd file
    // forces the chain to extend.
    test('second file triggers chain extension', () async {
      final raf = await tempMemoryFile();
      final fs = await formatWith(raf, smallSuper);

      expect(Meta.entriesCapacity(smallSuper), equals(1));

      await fs.writeFile('A.TXT', Uint8List.fromList([1]));
      await fs.writeFile('B.TXT', Uint8List.fromList([2]));

      expect(await fs.fileExists('A.TXT'), isTrue);
      expect(await fs.fileExists('B.TXT'), isTrue);
      expect(await fs.readFile('A.TXT'), equals(Uint8List.fromList([1])));
      expect(await fs.readFile('B.TXT'), equals(Uint8List.fromList([2])));
    });

    test('many files extend the Meta chain across multiple blocks', () async {
      final raf = await tempMemoryFile();
      final fs = await formatWith(raf, smallSuper);
      const fileCount = 5;

      for (var i = 0; i < fileCount; i++) {
        await fs.writeFile('F$i.TXT', Uint8List.fromList([i]));
      }

      final files = await fs.listFiles();
      expect(files.length, equals(fileCount));
      for (var i = 0; i < fileCount; i++) {
        expect(await fs.readFile('F$i.TXT'), equals(Uint8List.fromList([i])));
      }
    });

    test('chain extension persists across re-mount', () async {
      final raf = await tempMemoryFile();
      final fs1 = await formatWith(raf, smallSuper);
      await fs1.writeFile('A.TXT', Uint8List.fromList([10]));
      await fs1.writeFile('B.TXT', Uint8List.fromList([20]));

      final fs2 = await MicroFileSystem.mount(raf);
      expect(await fs2.readFile('A.TXT'), equals(Uint8List.fromList([10])));
      expect(await fs2.readFile('B.TXT'), equals(Uint8List.fromList([20])));
    });
  });

  // ---------------------------------------------------------------------------
  // Slot reuse after delete
  // ---------------------------------------------------------------------------
  group('Slot reuse', () {
    test('deleted slot is reused by subsequent write', () async {
      final raf = await tempMemoryFile();
      // Use smallSuper (capacity=1) so we can observe chain vs reuse clearly.
      final fs = await formatWith(raf, smallSuper);

      await fs.writeFile('OLD.TXT', Uint8List.fromList([1]));
      await fs.deleteFile('OLD.TXT');
      // Writing again should reuse the now-deleted slot rather than extending.
      await fs.writeFile('NEW.TXT', Uint8List.fromList([2]));

      // Only one live file, no chain growth beyond block 0.
      final files = await fs.listFiles();
      expect(files, equals(['NEW.TXT']));
    });
  });

  // ---------------------------------------------------------------------------
  // FileSystem interface (via _MicroFile / _MicroDirectory)
  // ---------------------------------------------------------------------------
  group('FileSystem interface', () {
    late RandomAccessFile raf;
    late MicroFileSystem fs;

    setUp(() async {
      raf = await tempMemoryFile();
      fs = await formatWith(raf, stdSuper);
    });

    test('file().exists() reflects write/delete', () async {
      final f = fs.file('THING.TXT');
      expect(await f.exists(), isFalse);
      await fs.writeFile('THING.TXT', Uint8List.fromList([7]));
      expect(await f.exists(), isTrue);
      await fs.deleteFile('THING.TXT');
      expect(await f.exists(), isFalse);
    });

    test('file().writeAsBytes() then readAsBytes() round-trip', () async {
      final f = fs.file('RW.BIN');
      final data = Uint8List.fromList([10, 20, 30, 40]);
      await f.writeAsBytes(data);
      expect(await f.readAsBytes(), equals(data));
    });

    test('file().length() returns correct size', () async {
      final f = fs.file('LEN.TXT');
      await f.writeAsBytes(Uint8List(128));
      expect(await f.length(), equals(128));
    });

    test('file().readAsString() / writeAsString() work via encoding', () async {
      final f = fs.file('TEXT.TXT');
      await f.writeAsString('Hello, World!');
      expect(await f.readAsString(), equals('Hello, World!'));
    });

    test('file().delete() removes file', () async {
      final f = fs.file('DEL.TXT');
      await f.writeAsBytes(Uint8List.fromList([1]));
      await f.delete();
      expect(await f.exists(), isFalse);
    });

    test('file().create() creates an empty file', () async {
      final f = fs.file('NEW.TXT');
      await f.create();
      expect(await f.exists(), isTrue);
      expect(await f.length(), equals(0));
    });

    test('file().stat() returns correct type and size', () async {
      final f = fs.file('STAT.TXT');
      await f.writeAsBytes(Uint8List(64));
      final stat = await f.stat();
      expect(stat.type, equals(FileSystemEntityType.file));
      expect(stat.size, equals(64));
    });

    test('file().stat() on missing file returns notFound', () async {
      final stat = await fs.file('NONE.TXT').stat();
      expect(stat.type, equals(FileSystemEntityType.notFound));
      expect(stat.size, equals(-1));
    });

    test('file().rename() moves the file', () async {
      final f = fs.file('OLD.TXT');
      await f.writeAsBytes(Uint8List.fromList([5, 6]));
      final newFile = await f.rename('/NEW.TXT');
      expect(await newFile.exists(), isTrue);
      expect(await newFile.readAsBytes(), equals(Uint8List.fromList([5, 6])));
      expect(await f.exists(), isFalse);
    });

    test('file().copy() duplicates the file', () async {
      final f = fs.file('SRC.TXT');
      await f.writeAsBytes(Uint8List.fromList([99]));
      await f.copy('/DEST.TXT');
      expect(await fs.fileExists('SRC.TXT'), isTrue);
      expect(await fs.fileExists('DEST.TXT'), isTrue);
      expect(await fs.readFile('DEST.TXT'), equals(Uint8List.fromList([99])));
    });

    test('directory(/).list() returns all live files', () async {
      await fs.writeFile('X.TXT', Uint8List.fromList([1]));
      await fs.writeFile('Y.TXT', Uint8List.fromList([2]));
      await fs.writeFile('Z.TXT', Uint8List.fromList([3]));
      await fs.deleteFile('Y.TXT');

      final entities = await fs.directory('/').list().toList();
      final names = entities.map((e) => e.basename).toSet();
      expect(names, equals({'X.TXT', 'Z.TXT'}));
    });

    test('isFile returns true for existing file', () async {
      await fs.writeFile('CHECK.TXT', Uint8List.fromList([1]));
      expect(await fs.isFile('CHECK.TXT'), isTrue);
      expect(await fs.isFile('MISSING.TXT'), isFalse);
    });

    test('isDirectory returns true only for root', () async {
      expect(await fs.isDirectory('/'), isTrue);
      expect(await fs.isDirectory('/somefile.txt'), isFalse);
    });

    test('type() returns correct entity types', () async {
      await fs.writeFile('T.TXT', Uint8List.fromList([1]));
      expect(
        await fs.type('T.TXT'),
        equals(FileSystemEntityType.file),
      );
      expect(
        await fs.type('/'),
        equals(FileSystemEntityType.directory),
      );
      expect(
        await fs.type('MISSING.TXT'),
        equals(FileSystemEntityType.notFound),
      );
    });

    test('identical returns true for same path', () async {
      expect(await fs.identical('foo.txt', '/foo.txt'), isTrue);
      expect(await fs.identical('foo.txt', 'bar.txt'), isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // Container growth
  // ---------------------------------------------------------------------------
  group('Container growth', () {
    // Helper: expected byte length of a container with exactly [blockCount]
    // blocks written (Super + blockCount blocks, no gaps).
    int expectedSize(Super s, int blockCount) =>
        Super.byteSize + blockCount * s.blockSize;

    test('format produces correct initial container size', () async {
      final raf = await tempMemoryFile();
      await formatWith(raf, stdSuper);
      // Super + block 0 (first Meta block).
      expect(await raf.length(), equals(expectedSize(stdSuper, 1)));
    });

    test('writing a file grows the container by one data block', () async {
      final raf = await tempMemoryFile();
      final fs = await formatWith(raf, stdSuper);
      await fs.writeFile('A.TXT', Uint8List.fromList([1]));
      // Super + block 0 (Meta) + block 1 (data for A.TXT).
      expect(await raf.length(), equals(expectedSize(stdSuper, 2)));
    });

    test('each additional file adds exactly one data block', () async {
      final raf = await tempMemoryFile();
      final fs = await formatWith(raf, stdSuper);
      for (var i = 1; i <= 5; i++) {
        await fs.writeFile('F$i.TXT', Uint8List.fromList([i]));
        // Super + 1 Meta block + i data blocks.
        expect(
          await raf.length(),
          equals(expectedSize(stdSuper, 1 + i)),
          reason: 'after writing $i files',
        );
      }
    });

    test('multi-block file grows the container by the correct number of blocks',
        () async {
      final raf = await tempMemoryFile();
      final fs = await formatWith(raf, stdSuper);
      // Write a file spanning 3 full blocks.
      final data = Uint8List(stdSuper.blockSize * 3);
      await fs.writeFile('BIG.DAT', data);
      // Super + 1 Meta block + 3 data blocks.
      expect(await raf.length(), equals(expectedSize(stdSuper, 4)));
    });

    test('meta chain extension adds an extra block for the new Meta block',
        () async {
      // smallSuper has capacity = 1 entry per block, so the 2nd file forces a
      // new Meta block to be added before the data block for that file.
      final raf = await tempMemoryFile();
      final fs = await formatWith(raf, smallSuper);

      // After format: Super + block 0 (Meta).
      expect(await raf.length(), equals(expectedSize(smallSuper, 1)));

      // Write first file: allocates 1 data block (block 1).
      await fs.writeFile('A.TXT', Uint8List.fromList([1]));
      expect(await raf.length(), equals(expectedSize(smallSuper, 2)));

      // Write second file: capacity=1 so first allocates a new Meta block
      // (block 2), then a data block (block 3).
      await fs.writeFile('B.TXT', Uint8List.fromList([2]));
      expect(await raf.length(), equals(expectedSize(smallSuper, 4)));
    });

    test('overwriting a file reuses the freed data block — container does not grow',
        () async {
      final raf = await tempMemoryFile();
      final fs = await formatWith(raf, stdSuper);
      await fs.writeFile('F.TXT', Uint8List.fromList([1, 2, 3]));
      final sizeAfterFirst = await raf.length();

      // Overwrite: writeFile deletes the old entry first (freeing its data
      // blocks), then calls _allocateBlocks which picks the now-free block
      // again.  The directory slot is also reused.  Net result: no growth.
      await fs.writeFile('F.TXT', Uint8List.fromList([9, 8, 7]));
      expect(await raf.length(), equals(sizeAfterFirst));
    });

    test('deleting a file does not shrink the container', () async {
      final raf = await tempMemoryFile();
      final fs = await formatWith(raf, stdSuper);
      await fs.writeFile('F.TXT', Uint8List.fromList([1]));
      final sizeAfterWrite = await raf.length();
      await fs.deleteFile('F.TXT');
      expect(await raf.length(), equals(sizeAfterWrite));
    });

    test('container size is correct after re-mount and further writes', () async {
      final raf = await tempMemoryFile();
      final fs1 = await formatWith(raf, stdSuper);
      await fs1.writeFile('A.TXT', Uint8List.fromList([1]));

      final fs2 = await MicroFileSystem.mount(raf);
      await fs2.writeFile('B.TXT', Uint8List.fromList([2]));
      // Super + Meta + data for A + data for B.
      expect(await raf.length(), equals(expectedSize(stdSuper, 3)));
    });
  });

  // ---------------------------------------------------------------------------
  // Simulated directories
  // ---------------------------------------------------------------------------
  group('Simulated directories', () {
    late RandomAccessFile raf;
    late MicroFileSystem fs;

    setUp(() async {
      raf = await tempMemoryFile();
      fs = await formatWith(raf, stdSuper);
    });

    test('nested file path is stored and retrieved correctly', () async {
      final f = fs.file('foo/bar/baz.txt');
      await f.writeAsString('hello');
      expect(await f.exists(), isTrue);
      expect(await f.readAsString(), equals('hello'));
      expect(await fs.fileExists('foo/bar/baz.txt'), isTrue);
    });

    test('directory exists() returns true when files are present under it', () async {
      await fs.file('a/b.txt').writeAsString('x');
      expect(await fs.directory('/a').exists(), isTrue);
    });

    test('directory exists() returns false when no files are present under it', () async {
      expect(await fs.directory('/ghost').exists(), isFalse);
    });

    test('directory list() yields direct child files', () async {
      await fs.file('/top/one.txt').writeAsString('1');
      await fs.file('/top/two.txt').writeAsString('2');
      final entities = await fs.directory('/top').list().toList();
      final names = entities.map((e) => e.basename).toSet();
      expect(names, equals({'one.txt', 'two.txt'}));
    });

    test('directory list() yields virtual subdirectory for nested files', () async {
      await fs.file('/root/sub/file.txt').writeAsString('deep');
      final entities = await fs.directory('/root').list().toList();
      expect(entities.length, equals(1));
      expect(entities.first, isA<Directory>());
      expect(entities.first.basename, equals('sub'));
    });

    test('directory list() deduplicates virtual subdirectories', () async {
      await fs.file('/p/q/a.txt').writeAsString('a');
      await fs.file('/p/q/b.txt').writeAsString('b');
      final entities = await fs.directory('/p').list().toList();
      expect(entities.length, equals(1));
      expect(entities.first.basename, equals('q'));
    });

    test('directory list(recursive: true) yields all nested files and dirs',
        () async {
      await fs.file('/tree/a.txt').writeAsString('a');
      await fs.file('/tree/sub/b.txt').writeAsString('b');
      final entities =
          await fs.directory('/tree').list(recursive: true).toList();
      final names = entities.map((e) => e.basename).toSet();
      expect(names, containsAll({'a.txt', 'sub', 'b.txt'}));
    });

    test('root list() returns direct-child files and virtual subdirectories', () async {
      await fs.file('/top.txt').writeAsString('t');
      await fs.file('/dir/nested.txt').writeAsString('n');
      final entities = await fs.directory('/').list().toList();
      final names = entities.map((e) => e.basename).toSet();
      expect(names, containsAll({'top.txt', 'dir'}));
      expect(names.length, equals(2));
    });

    test('childDirectory then childFile builds correct path', () async {
      await fs.file('/a/b/c.txt').writeAsString('abc');
      final dir = fs.directory('/a').childDirectory('b');
      final file = dir.childFile('c.txt');
      expect(await file.exists(), isTrue);
      expect(await file.readAsString(), equals('abc'));
    });

    test('directory delete(recursive: true) removes all children', () async {
      await fs.file('/del/x.txt').writeAsString('x');
      await fs.file('/del/sub/y.txt').writeAsString('y');
      await fs.directory('/del').delete(recursive: true);
      expect(await fs.fileExists('del/x.txt'), isFalse);
      expect(await fs.fileExists('del/sub/y.txt'), isFalse);
      expect(await fs.directory('/del').exists(), isFalse);
    });

    test('directory delete(recursive: false) throws when non-empty', () async {
      await fs.file('/notempty/a.txt').writeAsString('a');
      expect(
        () => fs.directory('/notempty').delete(),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('directory rename() moves all files under new prefix', () async {
      await fs.file('/old/x.txt').writeAsString('x content');
      await fs.file('/old/sub/y.txt').writeAsString('y content');
      await fs.directory('/old').rename('/new');
      expect(await fs.fileExists('new/x.txt'), isTrue);
      expect(await fs.fileExists('new/sub/y.txt'), isTrue);
      expect(await fs.fileExists('old/x.txt'), isFalse);
    });

    test('type() returns directory for path with files under it', () async {
      await fs.file('/d/f.txt').writeAsString('f');
      expect(await fs.type('/d'), equals(FileSystemEntityType.directory));
    });

    test('isDirectory returns true for path with files under it', () async {
      await fs.file('/mydir/file.txt').writeAsString('hi');
      expect(await fs.isDirectory('/mydir'), isTrue);
      expect(await fs.isDirectory('/other'), isFalse);
    });

    test('path too long throws FileSystemException', () async {
      // 49 UTF-8 bytes (exceeds 48-byte limit)
      final longName = 'a' * 49;
      final f = fs.file('/$longName');
      expect(
        () => f.create(),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('path at exactly 48 bytes is accepted', () async {
      final maxName = 'a' * 48;
      final f = fs.file('/$maxName');
      await f.create();
      expect(await f.exists(), isTrue);
    });

    test('directory path as prefix contributes to name length', () async {
      // 'dir/' (4) + 'file.txt' (8) = 12 bytes — well within limit
      final f = fs.file('/dir/file.txt');
      await f.writeAsString('ok');
      expect(await f.readAsString(), equals('ok'));
    });
  });

  // ---------------------------------------------------------------------------
  // file.open() / RandomAccessFile
  // ---------------------------------------------------------------------------
  group('file.open / RandomAccessFile', () {
    late RandomAccessFile raf;
    late MicroFileSystem fs;

    setUp(() async {
      raf = await tempMemoryFile();
      fs = await formatWith(raf, stdSuper);
    });

    test('open(read) reads existing file content', () async {
      await fs.file('r.bin').writeAsBytes(Uint8List.fromList([1, 2, 3]));
      final handle = await fs.file('r.bin').open();
      expect(await handle.length(), equals(3));
      expect(await handle.readByte(), equals(1));
      expect(await handle.readByte(), equals(2));
      expect(await handle.readByte(), equals(3));
      await handle.close();
    });

    test('open(read) on missing file throws FileSystemException', () async {
      expect(
        () => fs.file('missing.bin').open(),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('open(write) truncates existing content and writes new data', () async {
      await fs.file('w.bin').writeAsBytes(Uint8List.fromList([9, 9, 9, 9]));
      final handle =
          await fs.file('w.bin').open(mode: FileMode.write);
      await handle.writeFrom([1, 2]);
      await handle.close();
      expect(
        await fs.file('w.bin').readAsBytes(),
        equals(Uint8List.fromList([1, 2])),
      );
    });

    test('open(append) appends to existing content', () async {
      await fs.file('a.bin').writeAsBytes(Uint8List.fromList([1, 2]));
      final handle =
          await fs.file('a.bin').open(mode: FileMode.append);
      await handle.writeFrom([3, 4]);
      await handle.close();
      expect(
        await fs.file('a.bin').readAsBytes(),
        equals(Uint8List.fromList([1, 2, 3, 4])),
      );
    });

    test('setPosition and read work correctly', () async {
      await fs.file('p.bin')
          .writeAsBytes(Uint8List.fromList([10, 20, 30, 40, 50]));
      final handle = await fs.file('p.bin').open();
      await handle.setPosition(2);
      expect(await handle.position(), equals(2));
      final chunk = await handle.read(2);
      expect(chunk, equals(Uint8List.fromList([30, 40])));
      await handle.close();
    });

    test('truncate shortens the file on flush', () async {
      await fs.file('t.bin')
          .writeAsBytes(Uint8List.fromList([1, 2, 3, 4, 5]));
      final handle =
          await fs.file('t.bin').open(mode: FileMode.append);
      await handle.truncate(3);
      await handle.close();
      expect(
        await fs.file('t.bin').readAsBytes(),
        equals(Uint8List.fromList([1, 2, 3])),
      );
    });

    test('writeByte writes a single byte', () async {
      final handle =
          await fs.file('byte.bin').open(mode: FileMode.write);
      await handle.writeByte(0x42);
      await handle.close();
      expect(
        await fs.file('byte.bin').readAsBytes(),
        equals(Uint8List.fromList([0x42])),
      );
    });

    test('writeString encodes and writes UTF-8', () async {
      final handle =
          await fs.file('str.txt').open(mode: FileMode.write);
      await handle.writeString('hello');
      await handle.close();
      expect(await fs.file('str.txt').readAsString(), equals('hello'));
    });

    test('flush persists without closing', () async {
      final handle =
          await fs.file('flush.bin').open(mode: FileMode.write);
      await handle.writeFrom([7, 8, 9]);
      await handle.flush();
      expect(
        await fs.file('flush.bin').readAsBytes(),
        equals(Uint8List.fromList([7, 8, 9])),
      );
      await handle.close();
    });

    test('read(read-only) does not persist on close', () async {
      await fs.file('ro.bin').writeAsBytes(Uint8List.fromList([5]));
      final handle = await fs.file('ro.bin').open();
      // Reading does not dirty the buffer, so no write-back occurs.
      await handle.readByte();
      await handle.close();
      expect(
        await fs.file('ro.bin').readAsBytes(),
        equals(Uint8List.fromList([5])),
      );
    });

    test('readInto fills a list buffer', () async {
      await fs.file('ri.bin')
          .writeAsBytes(Uint8List.fromList([10, 20, 30]));
      final handle = await fs.file('ri.bin').open();
      final buf = List<int>.filled(3, 0);
      final count = await handle.readInto(buf);
      expect(count, equals(3));
      expect(buf, equals([10, 20, 30]));
      await handle.close();
    });

    test('operations on closed handle throw FileSystemException', () async {
      await fs.file('closed.bin').writeAsBytes(Uint8List.fromList([1]));
      final handle = await fs.file('closed.bin').open();
      await handle.close();
      expect(() => handle.readByte(), throwsA(isA<FileSystemException>()));
    });

    test('open() on nested path works correctly', () async {
      await fs.file('/sub/data.bin')
          .writeAsBytes(Uint8List.fromList([100, 200]));
      final handle = await fs.file('/sub/data.bin').open();
      expect(await handle.length(), equals(2));
      expect(await handle.readByte(), equals(100));
      await handle.close();
    });
  });
}
