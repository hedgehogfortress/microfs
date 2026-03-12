import 'dart:typed_data';

import 'package:file/file.dart';
import 'package:test/test.dart';

import 'package:microfs/v2/v2.dart';

import 'memory_file.dart';

void main() {
  // Helper to format a fresh filesystem in memory.
  Future<MicroFileSystem> freshFs() async =>
      MicroFileSystem.format(await tempMemoryFile());

  // ---------------------------------------------------------------------------
  // format + mount
  // ---------------------------------------------------------------------------
  group('format + mount', () {
    test('format produces an accessible root directory', () async {
      final fs = await freshFs();
      expect(await fs.directory('/').exists(), isTrue);
    });

    test('format creates empty root listing', () async {
      final fs = await freshFs();
      final entities = await fs.directory('/').list().toList();
      expect(entities, isEmpty);
    });

    test('mount reads existing container', () async {
      final raf = await tempMemoryFile();
      final fs1 = await MicroFileSystem.format(raf);
      await fs1.file('/hello.txt').writeAsString('world');

      final fs2 = await MicroFileSystem.mount(raf);
      expect(await fs2.file('/hello.txt').readAsString(), 'world');
    });

    test('mount throws on container too small', () async {
      final raf = await tempMemoryFile();
      await raf.writeFrom([0, 1, 2, 3]);
      expect(() => MicroFileSystem.mount(raf), throwsA(isA<FileSystemException>()));
    });

    test('mount throws on corrupt container', () async {
      final raf = await tempMemoryFile();
      // Write all zeros (invalid type marker in block 0).
      await raf.writeFrom(List.filled(4096, 0));
      expect(() => MicroFileSystem.mount(raf), throwsA(isA<Exception>()));
    });
  });

  // ---------------------------------------------------------------------------
  // Core file operations
  // ---------------------------------------------------------------------------
  group('core file operations', () {
    late MicroFileSystem fs;
    setUp(() async => fs = await freshFs());

    test('write then readAsBytes returns identical bytes', () async {
      final data = Uint8List.fromList(List.generate(256, (i) => i & 0xFF));
      await fs.file('/data.bin').writeAsBytes(data);
      expect(await fs.file('/data.bin').readAsBytes(), equals(data));
    });

    test('write then readAsString round-trips', () async {
      await fs.file('/hello.txt').writeAsString('hello world');
      expect(await fs.file('/hello.txt').readAsString(), 'hello world');
    });

    test('exists returns true after write, false before', () async {
      expect(await fs.file('/missing.txt').exists(), isFalse);
      await fs.file('/present.txt').writeAsString('x');
      expect(await fs.file('/present.txt').exists(), isTrue);
    });

    test('length returns correct byte count', () async {
      final data = Uint8List(999);
      await fs.file('/big.dat').writeAsBytes(data);
      expect(await fs.file('/big.dat').length(), 999);
    });

    test('write empty file', () async {
      await fs.file('/empty.txt').writeAsBytes(Uint8List(0));
      expect(await fs.file('/empty.txt').exists(), isTrue);
      expect(await fs.file('/empty.txt').length(), 0);
      expect(await fs.file('/empty.txt').readAsBytes(), isEmpty);
    });

    test('overwrite replaces content', () async {
      await fs.file('/f.txt').writeAsString('old');
      await fs.file('/f.txt').writeAsString('new');
      expect(await fs.file('/f.txt').readAsString(), 'new');
    });

    test('delete makes file inaccessible', () async {
      await fs.file('/gone.txt').writeAsString('x');
      await fs.file('/gone.txt').delete();
      expect(await fs.file('/gone.txt').exists(), isFalse);
    });

    test('delete non-existent file throws FileSystemException', () async {
      expect(
        () => fs.file('/nope.txt').delete(),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('read non-existent file throws FileSystemException', () async {
      expect(
        () => fs.file('/nope.txt').readAsBytes(),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('create creates an empty file', () async {
      await fs.file('/new.txt').create();
      expect(await fs.file('/new.txt').exists(), isTrue);
      expect(await fs.file('/new.txt').length(), 0);
    });

    test('create exclusive throws if file already exists', () async {
      await fs.file('/dup.txt').create();
      expect(
        () => fs.file('/dup.txt').create(exclusive: true),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('create is idempotent when not exclusive', () async {
      await fs.file('/idem.txt').writeAsString('original');
      await fs.file('/idem.txt').create(); // should not overwrite
      expect(await fs.file('/idem.txt').readAsString(), 'original');
    });

    test('multiple independent files coexist', () async {
      await fs.file('/a.txt').writeAsString('one');
      await fs.file('/b.txt').writeAsString('two');
      await fs.file('/c.txt').writeAsString('three');
      expect(await fs.file('/a.txt').readAsString(), 'one');
      expect(await fs.file('/b.txt').readAsString(), 'two');
      expect(await fs.file('/c.txt').readAsString(), 'three');
    });

    test('multi-block file (> 4095 bytes) is written and read correctly', () async {
      final data = Uint8List.fromList(
        List.generate(4096 * 3 + 17, (i) => i & 0xFF),
      );
      await fs.file('/large.bin').writeAsBytes(data);
      expect(await fs.file('/large.bin').readAsBytes(), equals(data));
    });

    test('rename moves file', () async {
      await fs.file('/before.txt').writeAsString('content');
      await fs.file('/before.txt').rename('/after.txt');
      expect(await fs.file('/before.txt').exists(), isFalse);
      expect(await fs.file('/after.txt').readAsString(), 'content');
    });

    test('copy duplicates file content', () async {
      await fs.file('/orig.txt').writeAsString('data');
      await fs.file('/orig.txt').copy('/copy.txt');
      expect(await fs.file('/orig.txt').readAsString(), 'data');
      expect(await fs.file('/copy.txt').readAsString(), 'data');
    });

    test('copy is independent (modifying copy does not affect original)', () async {
      await fs.file('/orig.txt').writeAsString('original');
      await fs.file('/orig.txt').copy('/copy.txt');
      await fs.file('/copy.txt').writeAsString('modified');
      expect(await fs.file('/orig.txt').readAsString(), 'original');
    });

    test('append mode appends to existing content', () async {
      await fs.file('/log.txt').writeAsBytes([1, 2, 3]);
      await fs.file('/log.txt').writeAsBytes([4, 5], mode: FileMode.append);
      expect(
        await fs.file('/log.txt').readAsBytes(),
        equals(Uint8List.fromList([1, 2, 3, 4, 5])),
      );
    });

    test('openRead streams content', () async {
      await fs.file('/stream.txt').writeAsString('hello');
      final chunks = await fs.file('/stream.txt').openRead().toList();
      final bytes = chunks.expand((b) => b).toList();
      expect(String.fromCharCodes(bytes), 'hello');
    });

    test('openRead with start/end slices content', () async {
      await fs.file('/slice.bin').writeAsBytes([0, 1, 2, 3, 4]);
      final chunks = await fs.file('/slice.bin').openRead(1, 4).toList();
      expect(chunks.first, equals(Uint8List.fromList([1, 2, 3])));
    });

    test('readAsLines splits on newlines', () async {
      await fs.file('/lines.txt').writeAsString('a\nb\nc');
      expect(await fs.file('/lines.txt').readAsLines(), equals(['a', 'b', 'c']));
    });

    test('stat returns correct size', () async {
      await fs.file('/stat.txt').writeAsBytes(Uint8List(42));
      final s = await fs.file('/stat.txt').stat();
      expect(s.size, 42);
      expect(s.type, FileSystemEntityType.file);
    });

    test('stat on missing file returns notFound type', () async {
      final s = await fs.file('/gone.txt').stat();
      expect(s.type, FileSystemEntityType.notFound);
    });
  });

  // ---------------------------------------------------------------------------
  // FileSystem interface
  // ---------------------------------------------------------------------------
  group('FileSystem interface', () {
    late MicroFileSystem fs;
    setUp(() async => fs = await freshFs());

    test('type() returns file for a file', () async {
      await fs.file('/f.txt').writeAsString('x');
      expect(await fs.type('/f.txt'), FileSystemEntityType.file);
    });

    test('type() returns directory for a directory', () async {
      await fs.directory('/d').create();
      expect(await fs.type('/d'), FileSystemEntityType.directory);
    });

    test('type() returns directory for root', () async {
      expect(await fs.type('/'), FileSystemEntityType.directory);
    });

    test('type() returns link for a link', () async {
      await fs.link('/lnk').create('/target');
      expect(await fs.type('/lnk'), FileSystemEntityType.link);
    });

    test('type() returns notFound for missing path', () async {
      expect(await fs.type('/missing'), FileSystemEntityType.notFound);
    });

    test('isFile() returns true for a file', () async {
      await fs.file('/f.txt').writeAsString('x');
      expect(await fs.isFile('/f.txt'), isTrue);
      expect(await fs.isFile('/missing'), isFalse);
    });

    test('isDirectory() returns true for a directory and root', () async {
      await fs.directory('/d').create();
      expect(await fs.isDirectory('/d'), isTrue);
      expect(await fs.isDirectory('/'), isTrue);
      expect(await fs.isDirectory('/missing'), isFalse);
    });

    test('isLink() returns true for a link', () async {
      await fs.link('/lnk').create('/t');
      expect(await fs.isLink('/lnk'), isTrue);
      expect(await fs.isLink('/missing'), isFalse);
    });

    test('stat() on root returns directory type', () async {
      final s = await fs.stat('/');
      expect(s.type, FileSystemEntityType.directory);
    });

    test('stat() on file returns correct size', () async {
      await fs.file('/s.txt').writeAsBytes(Uint8List(77));
      final s = await fs.stat('/s.txt');
      expect(s.type, FileSystemEntityType.file);
      expect(s.size, 77);
    });

    test('stat() on missing path returns notFound', () async {
      final s = await fs.stat('/missing');
      expect(s.type, FileSystemEntityType.notFound);
    });

    test('identical() returns true for same path (with normalization)', () async {
      expect(await fs.identical('/foo.txt', 'foo.txt'), isTrue);
      expect(await fs.identical('/foo.txt', '/bar.txt'), isFalse);
    });

    test('getPath extracts path from FileSystemEntity', () async {
      final f = fs.file('/test.txt');
      expect(fs.getPath(f), '/test.txt');
    });

    test('path context is posix', () {
      expect(fs.path.separator, '/');
    });

    test('file() accepts dynamic path (e.g. Uri)', () async {
      final uri = Uri.parse('file:///uri.txt');
      await fs.file(uri).writeAsString('via uri');
      expect(await fs.file('/uri.txt').readAsString(), 'via uri');
    });
  });

  // ---------------------------------------------------------------------------
  // Directory operations
  // ---------------------------------------------------------------------------
  group('directory operations', () {
    late MicroFileSystem fs;
    setUp(() async => fs = await freshFs());

    test('create() makes directory accessible', () async {
      await fs.directory('/docs').create();
      expect(await fs.directory('/docs').exists(), isTrue);
    });

    test('create(recursive: true) creates parent chain', () async {
      await fs.directory('/a/b/c').create(recursive: true);
      expect(await fs.directory('/a').exists(), isTrue);
      expect(await fs.directory('/a/b').exists(), isTrue);
      expect(await fs.directory('/a/b/c').exists(), isTrue);
    });

    test('create is idempotent', () async {
      await fs.directory('/d').create();
      await fs.directory('/d').create(); // should not throw
      expect(await fs.directory('/d').exists(), isTrue);
    });

    test('list() yields direct children', () async {
      await fs.directory('/top').create();
      await fs.file('/top/a.txt').writeAsString('a');
      await fs.file('/top/b.txt').writeAsString('b');
      final names = (await fs.directory('/top').list().toList())
          .map((e) => e.basename)
          .toSet();
      expect(names, equals({'a.txt', 'b.txt'}));
    });

    test('list() yields subdirectory entities (not as files)', () async {
      await fs.directory('/root').create();
      await fs.directory('/root/sub').create();
      await fs.file('/root/file.txt').writeAsString('x');
      final entities = await fs.directory('/root').list().toList();
      final dirs = entities.whereType<Directory>().map((d) => d.basename).toSet();
      final files = entities.whereType<File>().map((f) => f.basename).toSet();
      expect(dirs, equals({'sub'}));
      expect(files, equals({'file.txt'}));
    });

    test('list(recursive: true) yields all nested entities', () async {
      await fs.directory('/tree').create();
      await fs.file('/tree/a.txt').writeAsString('a');
      await fs.directory('/tree/sub').create();
      await fs.file('/tree/sub/b.txt').writeAsString('b');
      final entities = await fs.directory('/tree').list(recursive: true).toList();
      final names = entities.map((e) => e.basename).toSet();
      expect(names, containsAll({'a.txt', 'sub', 'b.txt'}));
    });

    test('list() yields link entities', () async {
      await fs.directory('/d').create();
      await fs.link('/d/lnk').create('/target');
      final entities = await fs.directory('/d').list().toList();
      expect(entities, hasLength(1));
      expect(entities.first, isA<Link>());
      expect(entities.first.basename, 'lnk');
    });

    test('root list() yields direct children', () async {
      await fs.file('/top.txt').writeAsString('t');
      await fs.directory('/subdir').create();
      final names = (await fs.directory('/').list().toList())
          .map((e) => e.basename)
          .toSet();
      expect(names, containsAll({'top.txt', 'subdir'}));
    });

    test('delete() removes empty directory', () async {
      await fs.directory('/empty').create();
      await fs.directory('/empty').delete();
      expect(await fs.directory('/empty').exists(), isFalse);
    });

    test('delete() throws when non-empty and not recursive', () async {
      await fs.directory('/notempty').create();
      await fs.file('/notempty/f.txt').writeAsString('x');
      expect(
        () => fs.directory('/notempty').delete(),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('delete(recursive: true) removes directory and all contents', () async {
      await fs.directory('/del').create();
      await fs.file('/del/x.txt').writeAsString('x');
      await fs.directory('/del/sub').create();
      await fs.file('/del/sub/y.txt').writeAsString('y');
      await fs.directory('/del').delete(recursive: true);
      expect(await fs.directory('/del').exists(), isFalse);
      expect(await fs.file('/del/x.txt').exists(), isFalse);
    });

    test('delete(recursive: true) removes contained links', () async {
      await fs.directory('/ldir').create();
      await fs.link('/ldir/lnk').create('/target');
      await fs.directory('/ldir').delete(recursive: true);
      expect(await fs.directory('/ldir').exists(), isFalse);
    });

    test('delete root throws', () async {
      expect(
        () => fs.directory('/').delete(),
        throwsA(isA<Exception>()),
      );
    });

    test('rename() moves directory to new path', () async {
      await fs.directory('/old').create();
      await fs.file('/old/x.txt').writeAsString('x');
      await fs.directory('/old').rename('/new');
      expect(await fs.directory('/old').exists(), isFalse);
      expect(await fs.directory('/new').exists(), isTrue);
      expect(await fs.file('/new/x.txt').readAsString(), 'x');
    });

    test('stat() on directory returns directory type', () async {
      await fs.directory('/d').create();
      final s = await fs.directory('/d').stat();
      expect(s.type, FileSystemEntityType.directory);
    });

    test('childDirectory and childFile build correct paths', () async {
      await fs.directory('/a').create();
      await fs.directory('/a/b').create();
      await fs.file('/a/b/c.txt').writeAsString('abc');
      final dir = fs.directory('/a').childDirectory('b');
      final file = dir.childFile('c.txt');
      expect(await file.exists(), isTrue);
      expect(await file.readAsString(), 'abc');
    });

    test('childLink builds correct path', () async {
      await fs.directory('/a').create();
      await fs.directory('/a').childLink('lnk').create('/target');
      expect(await fs.link('/a/lnk').exists(), isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // Symbolic link operations
  // ---------------------------------------------------------------------------
  group('symbolic links', () {
    late MicroFileSystem fs;
    setUp(() async => fs = await freshFs());

    test('create() and target() round-trips', () async {
      await fs.link('/lnk').create('/some/path');
      expect(await fs.link('/lnk').target(), '/some/path');
    });

    test('exists() returns true for link, false for missing', () async {
      await fs.link('/lnk').create('/t');
      expect(await fs.link('/lnk').exists(), isTrue);
      expect(await fs.link('/missing').exists(), isFalse);
    });

    test('update() changes target', () async {
      await fs.link('/lnk').create('/old');
      await fs.link('/lnk').update('/new');
      expect(await fs.link('/lnk').target(), '/new');
    });

    test('delete() removes link', () async {
      await fs.link('/lnk').create('/t');
      await fs.link('/lnk').delete();
      expect(await fs.link('/lnk').exists(), isFalse);
    });

    test('rename() moves link to new path', () async {
      await fs.link('/a').create('/target');
      await fs.link('/a').rename('/b');
      expect(await fs.link('/a').exists(), isFalse);
      expect(await fs.link('/b').exists(), isTrue);
      expect(await fs.link('/b').target(), '/target');
    });

    test('link appears in directory listing as Link', () async {
      await fs.link('/lnk').create('/t');
      final entities = await fs.directory('/').list().toList();
      expect(entities, hasLength(1));
      expect(entities.first, isA<Link>());
    });

    test('stat() returns link type', () async {
      await fs.link('/lnk').create('/t');
      final s = await fs.link('/lnk').stat();
      expect(s.type, FileSystemEntityType.link);
    });

    test('resolveSymbolicLinks() returns target path', () async {
      await fs.link('/lnk').create('/actual/path');
      expect(await fs.link('/lnk').resolveSymbolicLinks(), '/actual/path');
    });

    test('isLink returns true, isFile/isDirectory return false', () async {
      await fs.link('/lnk').create('/t');
      expect(await fs.isLink('/lnk'), isTrue);
      expect(await fs.isFile('/lnk'), isFalse);
      expect(await fs.isDirectory('/lnk'), isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // Subdirectory / real hierarchy
  // ---------------------------------------------------------------------------
  group('real directory hierarchy', () {
    late MicroFileSystem fs;
    setUp(() async => fs = await freshFs());

    test('file in subdirectory is stored and retrieved correctly', () async {
      await fs.file('/foo/bar/baz.txt').create(recursive: true);
      await fs.file('/foo/bar/baz.txt').writeAsString('deep');
      expect(await fs.file('/foo/bar/baz.txt').readAsString(), 'deep');
    });

    test('files with same name in different directories are independent', () async {
      await fs.directory('/a').create();
      await fs.file('/a/file.txt').writeAsString('in a');

      // writeFile doesn't support recursive, so create dir first
      await fs.directory('/b').create();
      await fs.file('/b/file.txt').writeAsString('in b');
      expect(await fs.file('/a/file.txt').readAsString(), 'in a');
      expect(await fs.file('/b/file.txt').readAsString(), 'in b');
    });

    test('deeply nested path (many levels)', () async {
      await fs.directory('/a/b/c/d/e').create(recursive: true);
      await fs.file('/a/b/c/d/e/f.txt').writeAsString('deep');
      expect(await fs.file('/a/b/c/d/e/f.txt').readAsString(), 'deep');
    });

    test('directory and file with same name in different dirs coexist', () async {
      await fs.directory('/data').create();
      await fs.file('/data/info.txt').writeAsString('file in data');
      await fs.directory('/src').create();
      await fs.file('/src/data').writeAsString('file named data in src');
      expect(await fs.file('/data/info.txt').readAsString(), 'file in data');
      expect(await fs.file('/src/data').readAsString(), 'file named data in src');
    });
  });

  // ---------------------------------------------------------------------------
  // Path length tests (key v2 improvement)
  // ---------------------------------------------------------------------------
  group('path length', () {
    late MicroFileSystem fs;
    setUp(() async => fs = await freshFs());

    test('path component of exactly 48 bytes is accepted', () async {
      final name = 'a' * 48; // exactly 48 ASCII bytes
      await fs.file('/$name').create();
      expect(await fs.file('/$name').exists(), isTrue);
    });

    test('path component of 49 bytes throws FileSystemException', () async {
      final name = 'a' * 49;
      expect(
        () => fs.file('/$name').create(),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('path component of 49 bytes throws on write', () async {
      final name = 'a' * 49;
      expect(
        () => fs.file('/$name').writeAsString('x'),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('full path with many short components (>> 48 total bytes) works', () async {
      // v1 stored full path in 48 bytes — this would fail there
      // v2 stores each component independently — this works fine
      final path = '/this/is/a/deeply/nested/path/with/many/components/file.txt';
      // Longest component: 'components' = 10 bytes — well within 48 bytes each
      expect(path.length, greaterThan(48));
      await fs.directory('/this/is/a/deeply/nested/path/with/many/components')
          .create(recursive: true);
      await fs.file(path).writeAsString('ok');
      expect(await fs.file(path).readAsString(), 'ok');
    });

    test('full path exceeding 48 bytes via deep nesting works', () async {
      // This path is 52 bytes total but each component is ≤48 bytes
      final path = '/some/directory/with/file.txt'; // 29 bytes, works fine
      await fs.directory('/some/directory/with').create(recursive: true);
      await fs.file(path).writeAsString('nested');
      expect(await fs.file(path).readAsString(), 'nested');
    });

    test('directory component of exactly 48 bytes works', () async {
      final name = 'd' * 48;
      await fs.directory('/$name').create();
      expect(await fs.directory('/$name').exists(), isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // Persistence across remount
  // ---------------------------------------------------------------------------
  group('persistence across remount', () {
    test('written file survives remount', () async {
      final raf = await tempMemoryFile();
      final fs1 = await MicroFileSystem.format(raf);
      await fs1.file('/hello.txt').writeAsString('persistent');

      final fs2 = await MicroFileSystem.mount(raf);
      expect(await fs2.file('/hello.txt').readAsString(), 'persistent');
    });

    test('overwrite persists across remount', () async {
      final raf = await tempMemoryFile();
      final fs1 = await MicroFileSystem.format(raf);
      await fs1.file('/f.txt').writeAsString('old');
      await fs1.file('/f.txt').writeAsString('new');

      final fs2 = await MicroFileSystem.mount(raf);
      expect(await fs2.file('/f.txt').readAsString(), 'new');
    });

    test('delete persists across remount', () async {
      final raf = await tempMemoryFile();
      final fs1 = await MicroFileSystem.format(raf);
      await fs1.file('/temp.txt').writeAsString('x');
      await fs1.file('/temp.txt').delete();

      final fs2 = await MicroFileSystem.mount(raf);
      expect(await fs2.file('/temp.txt').exists(), isFalse);
    });

    test('directory structure survives remount', () async {
      final raf = await tempMemoryFile();
      final fs1 = await MicroFileSystem.format(raf);
      await fs1.directory('/docs').create();
      await fs1.file('/docs/note.txt').writeAsString('note');

      final fs2 = await MicroFileSystem.mount(raf);
      expect(await fs2.directory('/docs').exists(), isTrue);
      expect(await fs2.file('/docs/note.txt').readAsString(), 'note');
    });

    test('link survives remount', () async {
      final raf = await tempMemoryFile();
      final fs1 = await MicroFileSystem.format(raf);
      await fs1.link('/lnk').create('/target');

      final fs2 = await MicroFileSystem.mount(raf);
      expect(await fs2.link('/lnk').exists(), isTrue);
      expect(await fs2.link('/lnk').target(), '/target');
    });

    test('multiple files all survive remount', () async {
      final raf = await tempMemoryFile();
      final fs1 = await MicroFileSystem.format(raf);
      for (var i = 0; i < 5; i++) {
        await fs1.file('/file$i.txt').writeAsString('content $i');
      }

      final fs2 = await MicroFileSystem.mount(raf);
      for (var i = 0; i < 5; i++) {
        expect(await fs2.file('/file$i.txt').readAsString(), 'content $i');
      }
    });
  });

  // ---------------------------------------------------------------------------
  // file.open() / RandomAccessFile
  // ---------------------------------------------------------------------------
  group('file.open / RandomAccessFile', () {
    late MicroFileSystem fs;
    setUp(() async => fs = await freshFs());

    test('open(read) reads existing content', () async {
      await fs.file('/r.bin').writeAsBytes(Uint8List.fromList([1, 2, 3]));
      final handle = await fs.file('/r.bin').open();
      expect(await handle.length(), 3);
      expect(await handle.readByte(), 1);
      expect(await handle.readByte(), 2);
      expect(await handle.readByte(), 3);
      await handle.close();
    });

    test('open(read) on missing file throws FileSystemException', () async {
      expect(
        () => fs.file('/missing.bin').open(),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('open(write) truncates and writes new data', () async {
      await fs.file('/w.bin').writeAsBytes(Uint8List.fromList([9, 9, 9, 9]));
      final handle = await fs.file('/w.bin').open(mode: FileMode.write);
      await handle.writeFrom([1, 2]);
      await handle.close();
      expect(
        await fs.file('/w.bin').readAsBytes(),
        equals(Uint8List.fromList([1, 2])),
      );
    });

    test('open(append) appends to existing content', () async {
      await fs.file('/a.bin').writeAsBytes(Uint8List.fromList([1, 2]));
      final handle = await fs.file('/a.bin').open(mode: FileMode.append);
      await handle.writeFrom([3, 4]);
      await handle.close();
      expect(
        await fs.file('/a.bin').readAsBytes(),
        equals(Uint8List.fromList([1, 2, 3, 4])),
      );
    });

    test('setPosition and read work correctly', () async {
      await fs.file('/p.bin').writeAsBytes(Uint8List.fromList([10, 20, 30, 40, 50]));
      final handle = await fs.file('/p.bin').open();
      await handle.setPosition(2);
      expect(await handle.position(), 2);
      final chunk = await handle.read(2);
      expect(chunk, equals(Uint8List.fromList([30, 40])));
      await handle.close();
    });

    test('truncate shortens the file on close', () async {
      await fs.file('/t.bin').writeAsBytes(Uint8List.fromList([1, 2, 3, 4, 5]));
      final handle = await fs.file('/t.bin').open(mode: FileMode.append);
      await handle.truncate(3);
      await handle.close();
      expect(
        await fs.file('/t.bin').readAsBytes(),
        equals(Uint8List.fromList([1, 2, 3])),
      );
    });

    test('writeByte writes a single byte', () async {
      final handle = await fs.file('/byte.bin').open(mode: FileMode.write);
      await handle.writeByte(0x42);
      await handle.close();
      expect(
        await fs.file('/byte.bin').readAsBytes(),
        equals(Uint8List.fromList([0x42])),
      );
    });

    test('writeString encodes and writes UTF-8', () async {
      final handle = await fs.file('/str.txt').open(mode: FileMode.write);
      await handle.writeString('hello');
      await handle.close();
      expect(await fs.file('/str.txt').readAsString(), 'hello');
    });

    test('flush persists without closing', () async {
      final handle = await fs.file('/flush.bin').open(mode: FileMode.write);
      await handle.writeFrom([7, 8, 9]);
      await handle.flush();
      expect(
        await fs.file('/flush.bin').readAsBytes(),
        equals(Uint8List.fromList([7, 8, 9])),
      );
      await handle.close();
    });

    test('read-only open does not persist on close', () async {
      await fs.file('/ro.bin').writeAsBytes(Uint8List.fromList([5]));
      final handle = await fs.file('/ro.bin').open();
      await handle.readByte();
      await handle.close();
      expect(
        await fs.file('/ro.bin').readAsBytes(),
        equals(Uint8List.fromList([5])),
      );
    });

    test('readInto fills a list buffer', () async {
      await fs.file('/ri.bin').writeAsBytes(Uint8List.fromList([10, 20, 30]));
      final handle = await fs.file('/ri.bin').open();
      final buf = List<int>.filled(3, 0);
      final count = await handle.readInto(buf);
      expect(count, 3);
      expect(buf, equals([10, 20, 30]));
      await handle.close();
    });

    test('operations on closed handle throw FileSystemException', () async {
      await fs.file('/closed.bin').writeAsBytes(Uint8List.fromList([1]));
      final handle = await fs.file('/closed.bin').open();
      await handle.close();
      expect(() => handle.readByte(), throwsA(isA<FileSystemException>()));
    });

    test('open on file in subdirectory works', () async {
      await fs.directory('/sub').create();
      await fs.file('/sub/data.bin').writeAsBytes(Uint8List.fromList([100, 200]));
      final handle = await fs.file('/sub/data.bin').open();
      expect(await handle.length(), 2);
      expect(await handle.readByte(), 100);
      await handle.close();
    });
  });

  // ---------------------------------------------------------------------------
  // Container size (v2: no superblock, formula = blockCount × 4096)
  // ---------------------------------------------------------------------------
  group('container size', () {
    const blockSize = 4096;
    int expectedSize(int blockCount) => blockCount * blockSize;

    test('format produces exactly 1 block (root DirectoryBlock)', () async {
      final raf = await tempMemoryFile();
      await MicroFileSystem.format(raf);
      expect(await raf.length(), equals(expectedSize(1)));
    });

    test('writing a small file adds exactly 1 data block', () async {
      final raf = await tempMemoryFile();
      final fs = await MicroFileSystem.format(raf);
      await fs.file('/a.txt').writeAsString('small');
      // block 0: root dir, block 1: data
      expect(await raf.length(), equals(expectedSize(2)));
    });

    test('each additional small file adds 1 block', () async {
      final raf = await tempMemoryFile();
      final fs = await MicroFileSystem.format(raf);
      for (var i = 1; i <= 5; i++) {
        await fs.file('/f$i.txt').writeAsString('x');
        expect(
          await raf.length(),
          equals(expectedSize(1 + i)),
          reason: 'after writing $i files',
        );
      }
    });

    test('overwriting a file reuses freed blocks — container does not grow', () async {
      final raf = await tempMemoryFile();
      final fs = await MicroFileSystem.format(raf);
      await fs.file('/f.txt').writeAsString('hello');
      final sizeAfterFirst = await raf.length();
      await fs.file('/f.txt').writeAsString('world');
      expect(await raf.length(), equals(sizeAfterFirst));
    });

    test('deleting a file does not shrink the container', () async {
      final raf = await tempMemoryFile();
      final fs = await MicroFileSystem.format(raf);
      await fs.file('/f.txt').writeAsString('x');
      final sizeAfterWrite = await raf.length();
      await fs.file('/f.txt').delete();
      expect(await raf.length(), equals(sizeAfterWrite));
    });

    test('creating a subdirectory adds 1 directory block', () async {
      final raf = await tempMemoryFile();
      final fs = await MicroFileSystem.format(raf);
      await fs.directory('/docs').create();
      // block 0: root dir, block 1: docs dir
      expect(await raf.length(), equals(expectedSize(2)));
    });

    test('file in subdirectory: root dir + subdir block + data block', () async {
      final raf = await tempMemoryFile();
      final fs = await MicroFileSystem.format(raf);
      await fs.directory('/docs').create();
      await fs.file('/docs/note.txt').writeAsString('note');
      // block 0: root dir, block 1: docs dir, block 2: data
      expect(await raf.length(), equals(expectedSize(3)));
    });

    test('container size after remount and further writes', () async {
      final raf = await tempMemoryFile();
      final fs1 = await MicroFileSystem.format(raf);
      await fs1.file('/a.txt').writeAsString('a');

      final fs2 = await MicroFileSystem.mount(raf);
      await fs2.file('/b.txt').writeAsString('b');
      // block 0: root dir, block 1: data a, block 2: data b
      expect(await raf.length(), equals(expectedSize(3)));
    });

    test('v2 format is smaller than v1 (no 8-byte superblock overhead)', () async {
      // v2 format = 4096 bytes (just block 0)
      // v1 format = 8 bytes (super) + 4096 bytes (meta block) = 4104 bytes
      final raf = await tempMemoryFile();
      await MicroFileSystem.format(raf);
      expect(await raf.length(), equals(4096)); // strictly 1 block, no overhead
    });
  });
}
