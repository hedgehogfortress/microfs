import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:file/file.dart';
import 'package:path/path.dart' as p;

import 'data.dart';
import 'engine.dart';

// =============================================================================
// _MicroFileStat
// =============================================================================

final class _MicroFileStat implements io.FileStat {
  const _MicroFileStat({
    required this.changed,
    required this.modified,
    required this.accessed,
    required this.type,
    required this.mode,
    required this.size,
  });

  static const int _permissionsMask = 0xFFF;
  static const int _ownerShift = 6;
  static const int _groupShift = 3;
  static const int _otherShift = 0;
  static const int _rwxMask = 0x7;

  static final notFound = _MicroFileStat(
    changed: DateTime.fromMillisecondsSinceEpoch(0),
    modified: DateTime.fromMillisecondsSinceEpoch(0),
    accessed: DateTime.fromMillisecondsSinceEpoch(0),
    type: io.FileSystemEntityType.notFound,
    mode: 0,
    size: -1,
  );

  @override final DateTime changed;
  @override final DateTime modified;
  @override final DateTime accessed;
  @override final io.FileSystemEntityType type;
  @override final int mode;
  @override final int size;

  @override
  String modeString() {
    final permissions = mode & _permissionsMask;
    const codes = ['---', '--x', '-w-', '-wx', 'r--', 'r-x', 'rw-', 'rwx'];
    return '${codes[(permissions >> _ownerShift) & _rwxMask]}'
        '${codes[(permissions >> _groupShift) & _rwxMask]}'
        '${codes[(permissions >> _otherShift) & _rwxMask]}';
  }
}

// =============================================================================
// _MicroFile
// =============================================================================

class _MicroFile implements File {
  final MicroFileSystem _fs;

  @override
  final String path;

  /// POSIX mode 0644 (rw-r--r--).
  static const int _fileMode = 0x1A4;

  _MicroFile(this._fs, this.path);

  String get _absPath => _fs._normalizePath(path);

  /// Throws if the basename of this file exceeds [DirectoryEntry.maxNameBytes].
  void _checkNameLength() {
    final name = p.posix.basename(_absPath);
    if (utf8.encode(name).length > DirectoryEntry.maxNameBytes) {
      throw io.FileSystemException('path component too long', path);
    }
  }

  @override FileSystem get fileSystem => _fs;
  @override bool get isAbsolute => p.posix.isAbsolute(path);
  @override Uri get uri => Uri.file(path, windows: false);
  @override File get absolute => _MicroFile(_fs, _absPath);
  @override Directory get parent => _fs.directory(p.posix.dirname(path));
  @override String get basename => p.posix.basename(path);
  @override String get dirname => p.posix.dirname(path);

  @override Future<bool> exists() => _fs._engine.isFile(_absPath);
  @override bool existsSync() => _unsync();

  @override
  Future<_MicroFileStat> stat() async {
    if (!await _fs._engine.isFile(_absPath)) return _MicroFileStat.notFound;
    final sz = await _fs._engine.fileSize(_absPath);
    final now = DateTime.now();
    return _MicroFileStat(
      changed: now, modified: now, accessed: now,
      type: io.FileSystemEntityType.file,
      mode: _fileMode,
      size: sz,
    );
  }

  @override io.FileStat statSync() => _unsync();

  @override Future<int> length() => _fs._engine.fileSize(_absPath);
  @override int lengthSync() => _unsync();

  @override
  Future<File> create({bool recursive = false, bool exclusive = false}) async {
    _checkNameLength();
    if (!await _fs._engine.exists(_absPath)) {
      await _fs._engine.writeFile(_absPath, Uint8List(0), recursive: recursive);
    } else if (exclusive) {
      throw io.FileSystemException('File already exists', path);
    }
    return this;
  }

  @override void createSync({bool recursive = false, bool exclusive = false}) => _unsync();

  @override
  Future<File> delete({bool recursive = false}) async {
    await _fs._engine.deleteFile(_absPath);
    return this;
  }

  @override void deleteSync({bool recursive = false}) => _unsync();

  @override
  Future<File> rename(String newPath) async {
    final target = _MicroFile(_fs, newPath);
    target._checkNameLength();
    await _fs._engine.renameEntry(_absPath, target._absPath);
    return target;
  }

  @override File renameSync(String newPath) => _unsync();

  @override
  Future<File> copy(String newPath) async {
    final target = _MicroFile(_fs, newPath);
    target._checkNameLength();
    await _fs._engine.copyFile(_absPath, target._absPath);
    return target;
  }

  @override File copySync(String newPath) => _unsync();

  @override Future<Uint8List> readAsBytes() => _fs._engine.readFile(_absPath);
  @override Uint8List readAsBytesSync() => _unsync();

  @override
  Future<String> readAsString({Encoding encoding = utf8}) async =>
      encoding.decode(await readAsBytes());

  @override String readAsStringSync({Encoding encoding = utf8}) => _unsync();

  @override
  Future<List<String>> readAsLines({Encoding encoding = utf8}) async =>
      (await readAsString(encoding: encoding)).split('\n');

  @override List<String> readAsLinesSync({Encoding encoding = utf8}) => _unsync();

  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    io.FileMode mode = io.FileMode.write,
    bool flush = false,
  }) async {
    _checkNameLength();
    final data = mode == io.FileMode.append && await _fs._engine.isFile(_absPath)
        ? Uint8List.fromList([...await _fs._engine.readFile(_absPath), ...bytes])
        : Uint8List.fromList(bytes);
    await _fs._engine.writeFile(_absPath, data);
    return this;
  }

  @override
  void writeAsBytesSync(
    List<int> bytes, {
    io.FileMode mode = io.FileMode.write,
    bool flush = false,
  }) => _unsync();

  @override
  Future<File> writeAsString(
    String contents, {
    io.FileMode mode = io.FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) => writeAsBytes(encoding.encode(contents), mode: mode, flush: flush);

  @override
  void writeAsStringSync(
    String contents, {
    io.FileMode mode = io.FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) => _unsync();

  @override
  Stream<Uint8List> openRead([int? start, int? end]) =>
      Stream.fromFuture(_fs._engine.readFile(_absPath)).map(
        (bytes) => bytes.sublist(start ?? 0, end?.clamp(0, bytes.length)),
      );

  @override
  io.IOSink openWrite({io.FileMode mode = io.FileMode.write, Encoding encoding = utf8}) =>
      throw UnsupportedError('openWrite is not supported; use writeAsBytes');

  @override
  Future<io.RandomAccessFile> open({io.FileMode mode = io.FileMode.read}) async {
    _checkNameLength();
    return _MicroRandomAccessFile._open(this, mode);
  }

  @override io.RandomAccessFile openSync({io.FileMode mode = io.FileMode.read}) => _unsync();

  @override Future<DateTime> lastAccessed() => Future.value(DateTime.fromMillisecondsSinceEpoch(0));
  @override DateTime lastAccessedSync() => _unsync();
  @override Future<void> setLastAccessed(DateTime time) async {}
  @override void setLastAccessedSync(DateTime time) => _unsync();
  @override Future<DateTime> lastModified() => Future.value(DateTime.fromMillisecondsSinceEpoch(0));
  @override DateTime lastModifiedSync() => _unsync();
  @override Future<void> setLastModified(DateTime time) async {}
  @override void setLastModifiedSync(DateTime time) => _unsync();

  @override
  Stream<io.FileSystemEvent> watch({
    int events = io.FileSystemEvent.all,
    bool recursive = false,
  }) => throw UnsupportedError('file watching is not supported');

  @override
  Future<String> resolveSymbolicLinks() => Future.value(absolute.path);

  @override String resolveSymbolicLinksSync() => _unsync();

  static Never _unsync() => throw UnsupportedError('sync operations are not supported');
}

// =============================================================================
// _MicroDirectory
// =============================================================================

class _MicroDirectory implements Directory {
  final MicroFileSystem _fs;

  @override final String path;

  /// POSIX mode 0755 (rwxr-xr-x).
  static const int _dirMode = 0x1ED;

  _MicroDirectory(this._fs, [String path = '/'])
      : path = _normalize(path);

  static String _normalize(String rawPath) {
    final t = rawPath.trim();
    return t.startsWith('/') ? t : '/$t';
  }

  bool get _isRoot => path == '/';

  @override FileSystem get fileSystem => _fs;
  @override bool get isAbsolute => true;
  @override Uri get uri => Uri.directory(path);
  @override Directory get absolute => this;
  @override Directory get parent =>
      _isRoot ? this : _fs.directory(p.posix.dirname(path));
  @override String get basename => _isRoot ? '' : p.posix.basename(path);
  @override String get dirname => _isRoot ? '/' : p.posix.dirname(path);

  @override
  Future<bool> exists() async {
    if (_isRoot) return true;
    return _fs._engine.isDirectory(path);
  }

  @override bool existsSync() => _unsync();

  @override
  Future<_MicroFileStat> stat() async {
    final now = DateTime.now();
    return _MicroFileStat(
      changed: now, modified: now, accessed: now,
      type: io.FileSystemEntityType.directory,
      mode: _dirMode,
      size: 0,
    );
  }

  @override io.FileStat statSync() => _unsync();

  @override
  Future<Directory> create({bool recursive = false}) async {
    await _fs._engine.createDirectory(path, recursive: recursive);
    return this;
  }

  @override void createSync({bool recursive = false}) => _unsync();

  @override
  Future<Directory> createTemp([String? prefix]) =>
      throw UnsupportedError('createTemp is not supported');
  @override Directory createTempSync([String? prefix]) => _unsync();

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    if (_isRoot) throw io.FileSystemException('cannot delete root directory', path);
    await _fs._engine.deleteDirectory(path, recursive: recursive);
    return this;
  }

  @override void deleteSync({bool recursive = false}) => _unsync();

  @override
  Future<Directory> rename(String newPath) async {
    if (_isRoot) throw UnsupportedError('cannot rename root directory');
    final normalNew = _fs._normalizePath(newPath);
    await _fs._engine.renameEntry(path, normalNew);
    return _MicroDirectory(_fs, normalNew);
  }

  @override Directory renameSync(String newPath) => _unsync();

  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) async* {
    final entries = await _fs._engine.listDirectory(path);
    for (final entry in entries) {
      final childPath = '$path${_isRoot ? '' : '/'}${entry.name}';
      if (entry.type == entryTypeFile) {
        yield _MicroFile(_fs, childPath);
      } else if (entry.type == entryTypeDirectory) {
        final subDir = _MicroDirectory(_fs, childPath);
        yield subDir;
        if (recursive) {
          yield* subDir.list(recursive: true, followLinks: followLinks);
        }
      } else if (entry.type == entryTypeLink) {
        yield _MicroLink(_fs, childPath);
      }
    }
  }

  @override List<FileSystemEntity> listSync({bool recursive = false, bool followLinks = true}) => _unsync();

  @override
  Stream<io.FileSystemEvent> watch({
    int events = io.FileSystemEvent.all,
    bool recursive = false,
  }) => throw UnsupportedError('file watching is not supported');

  @override Directory childDirectory(String basename) {
    final sep = _isRoot ? '' : '/';
    return _MicroDirectory(_fs, '$path$sep$basename');
  }

  @override File childFile(String basename) {
    final sep = _isRoot ? '' : '/';
    return _MicroFile(_fs, '$path$sep$basename');
  }

  @override Link childLink(String basename) {
    final sep = _isRoot ? '' : '/';
    return _MicroLink(_fs, '$path$sep$basename');
  }

  @override Future<String> resolveSymbolicLinks() => Future.value(path);
  @override String resolveSymbolicLinksSync() => _unsync();

  static Never _unsync() => throw UnsupportedError('sync operations are not supported');
}

// =============================================================================
// _MicroLink
// =============================================================================

class _MicroLink implements Link {
  final MicroFileSystem _fs;

  @override final String path;

  _MicroLink(this._fs, this.path);

  String get _absPath => _fs._normalizePath(path);

  @override FileSystem get fileSystem => _fs;
  @override bool get isAbsolute => p.posix.isAbsolute(path);
  @override Uri get uri => Uri.file(path, windows: false);
  @override Link get absolute => _MicroLink(_fs, _absPath);
  @override Directory get parent => _fs.directory(p.posix.dirname(path));
  @override String get basename => p.posix.basename(path);
  @override String get dirname => p.posix.dirname(path);

  @override Future<bool> exists() => _fs._engine.isLink(_absPath);
  @override bool existsSync() => false;

  @override
  Future<io.FileStat> stat() async {
    if (!await _fs._engine.isLink(_absPath)) return _MicroFileStat.notFound;
    final now = DateTime.now();
    return _MicroFileStat(
      changed: now, modified: now, accessed: now,
      type: io.FileSystemEntityType.link,
      mode: 0x1FF, // 0777
      size: 0,
    );
  }

  @override io.FileStat statSync() => _MicroFileStat.notFound;

  @override
  Future<Link> create(String target, {bool recursive = false}) async {
    await _fs._engine.createLink(_absPath, target);
    return this;
  }

  @override void createSync(String target, {bool recursive = false}) =>
      throw UnsupportedError('sync operations are not supported');

  @override
  Future<Link> update(String target) async {
    await _fs._engine.updateLink(_absPath, target);
    return this;
  }

  @override void updateSync(String target) =>
      throw UnsupportedError('sync operations are not supported');

  @override
  Future<String> target() => _fs._engine.readLink(_absPath);

  @override String targetSync() =>
      throw UnsupportedError('sync operations are not supported');

  @override
  Future<String> resolveSymbolicLinks() async => await _fs._engine.readLink(_absPath);

  @override String resolveSymbolicLinksSync() =>
      throw UnsupportedError('sync operations are not supported');

  @override
  Future<Link> rename(String newPath) async {
    final normalNew = _fs._normalizePath(newPath);
    await _fs._engine.renameEntry(_absPath, normalNew);
    return _MicroLink(_fs, normalNew);
  }

  @override Link renameSync(String newPath) =>
      throw UnsupportedError('sync operations are not supported');

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    await _fs._engine.deleteLink(_absPath);
    return this;
  }

  @override void deleteSync({bool recursive = false}) =>
      throw UnsupportedError('sync operations are not supported');

  @override
  Stream<io.FileSystemEvent> watch({
    int events = io.FileSystemEvent.all,
    bool recursive = false,
  }) => throw UnsupportedError('file watching is not supported');
}

// =============================================================================
// _MicroRandomAccessFile  (buffer-based, identical pattern to v1)
// =============================================================================

class _MicroRandomAccessFile implements io.RandomAccessFile {
  final _MicroFile _file;
  final bool _readOnly;
  Uint8List _buffer;
  int _position = 0;
  bool _dirty = false;
  bool _closed = false;

  _MicroRandomAccessFile._(this._file, this._readOnly, this._buffer);

  static Future<_MicroRandomAccessFile> _open(
    _MicroFile file,
    io.FileMode mode,
  ) async {
    final readOnly = mode == io.FileMode.read;
    final needsExisting = mode == io.FileMode.read ||
        mode == io.FileMode.append ||
        mode == io.FileMode.writeOnlyAppend;
    final truncate =
        mode == io.FileMode.write || mode == io.FileMode.writeOnly;

    Uint8List buffer;
    final engine = file._fs._engine;
    final absPath = file._absPath;

    if (truncate) {
      buffer = Uint8List(0);
    } else if (needsExisting || await engine.isFile(absPath)) {
      if (needsExisting && !await engine.isFile(absPath)) {
        throw io.FileSystemException('File not found', file.path);
      }
      buffer = await engine.isFile(absPath)
          ? await engine.readFile(absPath)
          : Uint8List(0);
    } else {
      buffer = Uint8List(0);
    }

    final raf = _MicroRandomAccessFile._(file, readOnly, buffer);
    if (mode == io.FileMode.append || mode == io.FileMode.writeOnlyAppend) {
      raf._position = buffer.length;
    }
    return raf;
  }

  void _checkClosed() {
    if (_closed) throw io.FileSystemException('RandomAccessFile is closed', _file.path);
  }

  void _growIfNeeded(int requiredLength) {
    if (_buffer.length < requiredLength) {
      final grown = Uint8List(requiredLength);
      grown.setAll(0, _buffer);
      _buffer = grown;
    }
  }

  @override String get path => _file.path;

  @override
  Future<void> close() async {
    _checkClosed();
    await flush();
    _closed = true;
  }

  @override
  Future<int> readByte() async {
    _checkClosed();
    if (_position >= _buffer.length) return -1;
    return _buffer[_position++];
  }

  @override
  Future<Uint8List> read(int bytes) async {
    _checkClosed();
    final end = (_position + bytes).clamp(0, _buffer.length);
    final result = _buffer.sublist(_position, end);
    _position = end;
    return result;
  }

  @override
  Future<int> readInto(List<int> buffer, [int start = 0, int? end]) async {
    _checkClosed();
    final endIdx = end ?? buffer.length;
    final count = (endIdx - start).clamp(0, _buffer.length - _position);
    for (var i = 0; i < count; i++) {
      buffer[start + i] = _buffer[_position + i];
    }
    _position += count;
    return count;
  }

  @override
  Future<io.RandomAccessFile> writeByte(int value) async {
    _checkClosed();
    _growIfNeeded(_position + 1);
    _buffer[_position++] = value & 0xFF;
    _dirty = true;
    return this;
  }

  @override
  Future<io.RandomAccessFile> writeFrom(
    List<int> buffer, [
    int start = 0,
    int? end,
  ]) async {
    _checkClosed();
    final endIdx = end ?? buffer.length;
    final count = endIdx - start;
    if (count <= 0) return this;
    _growIfNeeded(_position + count);
    for (var i = 0; i < count; i++) {
      _buffer[_position + i] = buffer[start + i] & 0xFF;
    }
    _position += count;
    _dirty = true;
    return this;
  }

  @override
  Future<io.RandomAccessFile> writeString(
    String string, {
    Encoding encoding = utf8,
  }) => writeFrom(encoding.encode(string));

  @override
  Future<int> position() async {
    _checkClosed();
    return _position;
  }

  @override
  Future<io.RandomAccessFile> setPosition(int position) async {
    _checkClosed();
    _position = position.clamp(0, _buffer.length);
    return this;
  }

  @override
  Future<io.RandomAccessFile> truncate(int length) async {
    _checkClosed();
    if (length < _buffer.length) {
      _buffer = _buffer.sublist(0, length);
      if (_position > length) _position = length;
    } else if (length > _buffer.length) {
      final grown = Uint8List(length);
      grown.setAll(0, _buffer);
      _buffer = grown;
    }
    _dirty = true;
    return this;
  }

  @override
  Future<int> length() async {
    _checkClosed();
    return _buffer.length;
  }

  @override
  Future<io.RandomAccessFile> flush() async {
    _checkClosed();
    if (_dirty && !_readOnly) {
      await _file._fs._engine.writeFile(_file._absPath, _buffer);
      _dirty = false;
    }
    return this;
  }

  @override
  Future<io.RandomAccessFile> lock([
    io.FileLock mode = io.FileLock.exclusive,
    int start = 0,
    int end = -1,
  ]) async => this;

  @override
  Future<io.RandomAccessFile> unlock([int start = 0, int end = -1]) async => this;

  // Sync methods — not supported.
  static Never _unsync() => throw UnsupportedError('sync operations are not supported');
  @override void closeSync() => _unsync();
  @override int readByteSync() => _unsync();
  @override Uint8List readSync(int bytes) => _unsync();
  @override int readIntoSync(List<int> buffer, [int start = 0, int? end]) => _unsync();
  @override int writeByteSync(int value) => _unsync();
  @override void writeFromSync(List<int> buffer, [int start = 0, int? end]) => _unsync();
  @override void writeStringSync(String string, {Encoding encoding = utf8}) => _unsync();
  @override int positionSync() => _unsync();
  @override void setPositionSync(int position) => _unsync();
  @override void truncateSync(int length) => _unsync();
  @override int lengthSync() => _unsync();
  @override void flushSync() => _unsync();
  @override void lockSync([io.FileLock mode = io.FileLock.exclusive, int start = 0, int end = -1]) => _unsync();
  @override void unlockSync([int start = 0, int end = -1]) => _unsync();
}

// =============================================================================
// MicroFileSystem
// =============================================================================

/// A [FileSystem] implementation backed by a single binary container file.
///
/// Wraps [MicroFsEngine] with the `package:file` API.
/// Block 0 is always the root directory.
/// No superblock: the container is exactly `blockCount × 4096` bytes.
final class MicroFileSystem implements FileSystem {
  final MicroFsEngine _engine;

  MicroFileSystem._(this._engine);

  late final _MicroDirectory _root = _MicroDirectory(this);

  // ── Static factories ────────────────────────────────────────────────────────

  /// Formats a new filesystem into [raf] and returns a mounted instance.
  static Future<MicroFileSystem> format(io.RandomAccessFile raf) async {
    final engine = await MicroFsEngine.format(raf);
    return MicroFileSystem._(engine);
  }

  /// Mounts an existing filesystem from [raf].
  static Future<MicroFileSystem> mount(io.RandomAccessFile raf) async {
    final engine = await MicroFsEngine.mount(raf);
    return MicroFileSystem._(engine);
  }

  // ── Internal helpers ────────────────────────────────────────────────────────

  /// Normalizes a path to start with `/`.
  String _normalizePath(String rawPath) {
    final t = rawPath.trim();
    if (t.isEmpty || t == '/') return '/';
    return t.startsWith('/') ? t : '/$t';
  }

  // ── FileSystem interface ─────────────────────────────────────────────────────

  @override
  p.Context get path => p.posix;

  @override
  Directory get currentDirectory => _root;

  @override
  set currentDirectory(dynamic value) =>
      throw UnsupportedError('currentDirectory is read-only');

  @override
  Directory get systemTempDirectory => _root;

  @override
  bool get isWatchSupported => false;

  @override
  File file(dynamic path) => _MicroFile(this, _normalizePath(getPath(path)));

  @override
  Directory directory(dynamic path) => _MicroDirectory(this, getPath(path));

  @override
  Link link(dynamic path) => _MicroLink(this, getPath(path));

  @override
  String getPath(dynamic path) {
    if (path is io.FileSystemEntity) return path.path;
    if (path is Uri) return path.toFilePath();
    return path.toString();
  }

  @override
  Future<bool> identical(String path1, String path2) =>
      Future.value(_normalizePath(path1) == _normalizePath(path2));

  @override
  bool identicalSync(String path1, String path2) =>
      _normalizePath(path1) == _normalizePath(path2);

  @override
  Future<io.FileSystemEntityType> type(
    String path, {
    bool followLinks = true,
  }) async {
    final norm = _normalizePath(path);
    if (norm == '/') return io.FileSystemEntityType.directory;
    if (await _engine.isLink(norm)) return io.FileSystemEntityType.link;
    if (await _engine.isFile(norm)) return io.FileSystemEntityType.file;
    if (await _engine.isDirectory(norm)) return io.FileSystemEntityType.directory;
    return io.FileSystemEntityType.notFound;
  }

  @override
  io.FileSystemEntityType typeSync(String path, {bool followLinks = true}) =>
      throw UnsupportedError('sync operations are not supported');

  @override
  Future<bool> isFile(String path) => _engine.isFile(_normalizePath(path));

  @override
  bool isFileSync(String path) =>
      throw UnsupportedError('sync operations are not supported');

  @override
  Future<bool> isDirectory(String path) async {
    final norm = _normalizePath(path);
    if (norm == '/') return true;
    return _engine.isDirectory(norm);
  }

  @override
  bool isDirectorySync(String path) =>
      throw UnsupportedError('sync operations are not supported');

  @override
  Future<bool> isLink(String path) => _engine.isLink(_normalizePath(path));

  @override
  bool isLinkSync(String path) =>
      throw UnsupportedError('sync operations are not supported');

  @override
  Future<io.FileStat> stat(String path) async {
    final norm = _normalizePath(path);
    final now = DateTime.now();
    if (norm == '/') {
      return _MicroFileStat(
        changed: now, modified: now, accessed: now,
        type: io.FileSystemEntityType.directory,
        mode: 0x1ED,
        size: 0,
      );
    }
    if (await _engine.isLink(norm)) {
      return _MicroFileStat(
        changed: now, modified: now, accessed: now,
        type: io.FileSystemEntityType.link,
        mode: 0x1FF,
        size: 0,
      );
    }
    if (await _engine.isFile(norm)) {
      final sz = await _engine.fileSize(norm);
      return _MicroFileStat(
        changed: now, modified: now, accessed: now,
        type: io.FileSystemEntityType.file,
        mode: 0x1A4,
        size: sz,
      );
    }
    if (await _engine.isDirectory(norm)) {
      return _MicroFileStat(
        changed: now, modified: now, accessed: now,
        type: io.FileSystemEntityType.directory,
        mode: 0x1ED,
        size: 0,
      );
    }
    return _MicroFileStat.notFound;
  }

  @override
  io.FileStat statSync(String path) =>
      throw UnsupportedError('sync operations are not supported');
}
