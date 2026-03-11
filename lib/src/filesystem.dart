import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:file/file.dart';
import 'package:path/path.dart' as p;

import 'data.dart';

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

  /// Unix permission bits mask (lower 12 bits of mode).
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

  /// The relative path stored as the filename key inside the container
  /// (normalized path with the leading '/' stripped).
  String get _name {
    final norm = _fs._normalizePath(path);
    return norm.startsWith('/') ? norm.substring(1) : norm;
  }

  /// Maximum byte length of a stored filename (UTF-8 encoded).
  static const int _maxNameBytes = DirectoryEntry.maxFilenameLength;

  /// Throws [io.FileSystemException] if [_name] is too long to store.
  void _checkNameLength() {
    if (utf8.encode(_name).length > _maxNameBytes) {
      throw io.FileSystemException('path too long', path);
    }
  }

  @override FileSystem get fileSystem => _fs;
  @override bool get isAbsolute => p.posix.isAbsolute(path);
  @override Uri get uri => Uri.file(path, windows: false);
  @override File get absolute => _MicroFile(_fs, isAbsolute ? path : '/$path');
  @override Directory get parent => _fs.directory(p.posix.dirname(path));
  @override String get basename => p.posix.basename(path);
  @override String get dirname => p.posix.dirname(path);

  @override Future<bool> exists() => _fs.fileExists(_name);
  @override bool existsSync() => _unsync();

  @override
  Future<_MicroFileStat> stat() async {
    if (!await _fs.fileExists(_name)) return _MicroFileStat.notFound;
    final sz = await _fs.fileSize(_name);
    final now = DateTime.now();
    return _MicroFileStat(
      changed: now, modified: now, accessed: now,
      type: io.FileSystemEntityType.file,
      mode: _fileMode,
      size: sz,
    );
  }

  @override io.FileStat statSync() => _unsync();

  @override Future<int> length() => _fs.fileSize(_name);
  @override int lengthSync() => _unsync();

  @override
  Future<File> create({bool recursive = false, bool exclusive = false}) async {
    _checkNameLength();
    if (!await _fs.fileExists(_name)) {
      await _fs.writeFile(_name, Uint8List(0));
    } else if (exclusive) {
      throw io.FileSystemException('File already exists', path);
    }
    return this;
  }

  @override void createSync({bool recursive = false, bool exclusive = false}) => _unsync();

  @override
  Future<File> delete({bool recursive = false}) async {
    await _fs.deleteFile(_name);
    return this;
  }

  @override void deleteSync({bool recursive = false}) => _unsync();

  @override
  Future<File> rename(String newPath) async {
    final data = await _fs.readFile(_name);
    await _fs.deleteFile(_name);
    final target = _MicroFile(_fs, newPath);
    target._checkNameLength();
    await _fs.writeFile(target._name, data);
    return target;
  }

  @override File renameSync(String newPath) => _unsync();

  @override
  Future<File> copy(String newPath) async {
    final data = await _fs.readFile(_name);
    final target = _MicroFile(_fs, newPath);
    target._checkNameLength();
    await _fs.writeFile(target._name, data);
    return target;
  }

  @override File copySync(String newPath) => _unsync();

  @override Future<Uint8List> readAsBytes() => _fs.readFile(_name);
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
    final data = mode == io.FileMode.append && await _fs.fileExists(_name)
        ? Uint8List.fromList([...await _fs.readFile(_name), ...bytes])
        : Uint8List.fromList(bytes);
    await _fs.writeFile(_name, data);
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
      Stream.fromFuture(_fs.readFile(_name)).map(
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

  @override
  String resolveSymbolicLinksSync() => _unsync();

  static Never _unsync() => throw UnsupportedError('sync operations are not supported');
}

// =============================================================================
// _MicroDirectory
// =============================================================================

class _MicroDirectory implements Directory {
  final MicroFileSystem _fs;

  /// Normalised path (always starts with '/').
  @override final String path;

  /// POSIX mode 0755 (rwxr-xr-x).
  static const int _dirMode = 0x1ED;

  _MicroDirectory(this._fs, [String path = '/'])
      : path = (path.trim().startsWith('/') ? path.trim() : '/${path.trim()}');

  bool get _isRoot => path == '/';

  /// Relative path prefix used to identify files in this directory
  /// (e.g. 'foo/bar' for path '/foo/bar'). Empty string for root.
  String get _relPrefix => _isRoot ? '' : path.substring(1);

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
    final prefix = '$_relPrefix/';
    final files = await _fs.listFiles();
    return files.any((f) => f.startsWith(prefix));
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
  Future<Directory> create({bool recursive = false}) async => this;
  @override void createSync({bool recursive = false}) => _unsync();

  @override
  Future<Directory> createTemp([String? prefix]) =>
      throw UnsupportedError('createTemp is not supported');
  @override Directory createTempSync([String? prefix]) => _unsync();

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    if (_isRoot) {
      throw io.FileSystemException('cannot delete root directory', path);
    }
    final prefix = '$_relPrefix/';
    final files = await _fs.listFiles();
    final children = files.where((f) => f.startsWith(prefix)).toList();
    if (!recursive && children.isNotEmpty) {
      throw io.FileSystemException('Directory not empty', path);
    }
    for (final f in children) {
      await _fs.deleteFile(f);
    }
    return this;
  }

  @override void deleteSync({bool recursive = false}) => _unsync();

  @override
  Future<Directory> rename(String newPath) async {
    if (_isRoot) throw UnsupportedError('cannot rename root directory');
    final normalNew = _fs._normalizePath(newPath);
    final oldPrefix = '$_relPrefix/';
    final newRelPrefix =
        normalNew.startsWith('/') ? normalNew.substring(1) : normalNew;
    final files = await _fs.listFiles();
    for (final f in files.where((f) => f.startsWith(oldPrefix))) {
      final data = await _fs.readFile(f);
      await _fs.deleteFile(f);
      final newName = '$newRelPrefix/${f.substring(oldPrefix.length)}';
      await _fs.writeFile(newName, data);
    }
    return _MicroDirectory(_fs, newPath);
  }

  @override Directory renameSync(String newPath) => _unsync();

  @override
  Stream<FileSystemEntity> list({bool recursive = false, bool followLinks = true}) async* {
    final files = await _fs.listFiles();
    final prefix = _isRoot ? '' : '$_relPrefix/';
    final emittedDirs = <String>{};

    for (final filename in files) {
      if (!filename.startsWith(prefix)) continue;
      final relative = filename.substring(prefix.length); // portion after this dir
      if (relative.isEmpty) continue;

      final slashIdx = relative.indexOf('/');
      if (slashIdx == -1) {
        // Direct child file.
        yield _MicroFile(_fs, '/$filename');
      } else {
        // Belongs to a subdirectory.
        final subdirName = relative.substring(0, slashIdx);
        final subdirPath = '$path${_isRoot ? '' : '/'}$subdirName';
        if (emittedDirs.add(subdirPath)) {
          final subDir = _MicroDirectory(_fs, subdirPath);
          yield subDir;
          if (recursive) yield* subDir.list(recursive: true, followLinks: followLinks);
        }
      }
    }
  }

  @override List<FileSystemEntity> listSync({bool recursive = false, bool followLinks = true}) => _unsync();

  @override
  Stream<io.FileSystemEvent> watch({
    int events = io.FileSystemEvent.all,
    bool recursive = false,
  }) => throw UnsupportedError('file watching is not supported');

  @override Directory childDirectory(String basename) =>
      _MicroDirectory(_fs, '$path${_isRoot ? '' : '/'}$basename');
  @override File childFile(String basename) =>
      _MicroFile(_fs, '$path${_isRoot ? '' : '/'}$basename');
  @override Link childLink(String basename) =>
      _MicroLink(_fs, '$path${_isRoot ? '' : '/'}$basename');

  @override
  Future<String> resolveSymbolicLinks() => Future.value(path);

  @override
  String resolveSymbolicLinksSync() => _unsync();

  static Never _unsync() => throw UnsupportedError('sync operations are not supported');
}

// =============================================================================
// _MicroLink  (links are not supported — stubs that throw UnsupportedError)
// =============================================================================

class _MicroLink implements Link {
  final MicroFileSystem _fs;
  @override final String path;

  _MicroLink(this._fs, this.path);

  @override FileSystem get fileSystem => _fs;
  @override bool get isAbsolute => p.posix.isAbsolute(path);
  @override Uri get uri => Uri.file(path, windows: false);
  @override Link get absolute => _MicroLink(_fs, isAbsolute ? path : '/$path');
  @override Directory get parent => _fs.directory(p.posix.dirname(path));
  @override String get basename => p.posix.basename(path);
  @override String get dirname => p.posix.dirname(path);

  @override Future<bool> exists() => Future.value(false);
  @override bool existsSync() => false;
  @override Future<io.FileStat> stat() async => _MicroFileStat.notFound;
  @override io.FileStat statSync() => _MicroFileStat.notFound;

  static Never _unsupported() => throw UnsupportedError('links are not supported');

  @override Future<Link> rename(String newPath) => _unsupported();
  @override Link renameSync(String newPath) => _unsupported();
  @override Future<FileSystemEntity> delete({bool recursive = false}) => _unsupported();
  @override void deleteSync({bool recursive = false}) => _unsupported();
  @override Stream<io.FileSystemEvent> watch({int events = io.FileSystemEvent.all, bool recursive = false}) => _unsupported();
  @override Future<Link> create(String target, {bool recursive = false}) => _unsupported();
  @override void createSync(String target, {bool recursive = false}) => _unsupported();
  @override Future<Link> update(String target) => _unsupported();
  @override void updateSync(String target) => _unsupported();
  @override Future<String> resolveSymbolicLinks() => _unsupported();
  @override String resolveSymbolicLinksSync() => _unsupported();
  @override Future<String> target() => _unsupported();
  @override String targetSync() => _unsupported();
}

// =============================================================================
// _MicroRandomAccessFile  (buffer-based RandomAccessFile backed by _MicroFile)
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
    if (truncate) {
      buffer = Uint8List(0);
    } else if (needsExisting || await file._fs.fileExists(file._name)) {
      if (needsExisting && !await file._fs.fileExists(file._name)) {
        throw io.FileSystemException('File not found', file.path);
      }
      buffer = await file._fs.fileExists(file._name)
          ? await file._fs.readFile(file._name)
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

  @override
  String get path => _file.path;

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
      await _file._fs.writeFile(_file._name, _buffer);
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

final class MicroFileSystem implements FileSystem {
  final io.RandomAccessFile _raf;
  final Super _super;

  MicroFileSystem._(this._raf, this._super);

  late final _MicroDirectory _root = _MicroDirectory(this);

  // ---------------------------------------------------------------------------
  // Static factories
  // ---------------------------------------------------------------------------

  /// Formats a new microfs filesystem into [raf] using the given block parameters.
  /// Writes the Super and an initial empty Meta block (block 0), then returns
  /// a mounted [MicroFileSystem] ready for use.
  static Future<MicroFileSystem> format(
    io.RandomAccessFile raf, {
    required int blockSize,
    required int maxBlocksPerFile,
  }) async {
    final s = Super(blockSize: blockSize, maxBlocksPerFile: maxBlocksPerFile);
    await raf.setPosition(0);
    await raf.writeFrom(s.toBytes());
    await raf.writeFrom(Meta.empty(s).toBytes(s));
    await raf.flush();
    return MicroFileSystem._(raf, s);
  }

  /// Mounts an existing microfs container by reading the Super from [raf].
  /// Throws [io.FileSystemException] if the container is too small or has a
  /// corrupt super block.
  static Future<MicroFileSystem> mount(io.RandomAccessFile raf) async {
    await raf.setPosition(0);
    final superBytes = Uint8List.fromList(await raf.read(Super.byteSize));
    if (superBytes.length < Super.byteSize) {
      throw io.FileSystemException('container too small to be valid');
    }
    final s = Super.fromBytes(superBytes);
    if (s.blockSize == 0 || s.maxBlocksPerFile == 0) {
      throw io.FileSystemException('corrupt super block');
    }
    final fileLength = await raf.length();
    if (fileLength < Super.byteSize + s.blockSize) {
      throw io.FileSystemException('container too small to be valid');
    }
    return MicroFileSystem._(raf, s);
  }

  // ---------------------------------------------------------------------------
  // Low-level I/O helpers
  // ---------------------------------------------------------------------------

  Future<void> _writeAt(int offset, List<int> data) async {
    await _raf.setPosition(offset);
    await _raf.writeFrom(data);
  }

  /// Reads [length] bytes from [offset], zero-padding if the file is shorter.
  Future<Uint8List> _readAt(int offset, int length) async {
    await _raf.setPosition(offset);
    final bytes = Uint8List.fromList(await _raf.read(length));
    if (bytes.length < length) {
      final padded = Uint8List(length);
      padded.setAll(0, bytes);
      return padded;
    }
    return bytes;
  }

  /// Byte offset of the start of [blockIndex] in the container file.
  int _blockOffset(int blockIndex) =>
      Super.byteSize + blockIndex * _super.blockSize;

  Future<Meta> _readMeta(int blockIndex) async =>
      Meta.fromBytes(await _readAt(_blockOffset(blockIndex), _super.blockSize), _super);

  Future<void> _writeMeta(int blockIndex, Meta meta) =>
      _writeAt(_blockOffset(blockIndex), meta.toBytes(_super));

  Future<Uint8List> _readBlock(int blockIndex) =>
      _readAt(_blockOffset(blockIndex), _super.blockSize);

  Future<void> _writeBlock(int blockIndex, Uint8List data) {
    final padded = Uint8List(_super.blockSize);
    padded.setAll(0, data.take(_super.blockSize));
    return _writeAt(_blockOffset(blockIndex), padded);
  }

  // ---------------------------------------------------------------------------
  // Filesystem engine
  // ---------------------------------------------------------------------------

  /// Returns every entry (including deleted) from all Meta blocks, with their
  /// location (metaBlock index and slot index within that block).
  Future<List<({int metaBlock, int slot, DirectoryEntry entry})>> _allEntries() async {
    final results = <({int metaBlock, int slot, DirectoryEntry entry})>[];
    int? metaBlock = 0;
    while (metaBlock != null) {
      final meta = await _readMeta(metaBlock);
      for (var i = 0; i < meta.entries.length; i++) {
        results.add((metaBlock: metaBlock, slot: i, entry: meta.entries[i]));
      }
      metaBlock = meta.nextMetaOffset;
    }
    return results;
  }

  /// Finds the location of the live (non-deleted) entry for [filename].
  Future<({int metaBlock, int slot})?> _findSlot(String filename) async {
    int? metaBlock = 0;
    while (metaBlock != null) {
      final meta = await _readMeta(metaBlock);
      for (var i = 0; i < meta.entries.length; i++) {
        final entry = meta.entries[i];
        if (!entry.deleted && entry.filename == filename) {
          return (metaBlock: metaBlock, slot: i);
        }
      }
      metaBlock = meta.nextMetaOffset;
    }
    return null;
  }

  /// Finds a reusable (deleted or empty) directory slot, extending the Meta
  /// chain with a new block if no free slot is available.
  Future<({int metaBlock, int slot})> _findOrAllocateFreeSlot() async {
    int? metaBlock = 0;
    int lastMetaBlock = 0;
    while (metaBlock != null) {
      final meta = await _readMeta(metaBlock);
      for (var i = 0; i < meta.entries.length; i++) {
        final entry = meta.entries[i];
        if (entry.deleted || (entry.filename.isEmpty && entry.fileId == 0)) {
          return (metaBlock: metaBlock, slot: i);
        }
      }
      lastMetaBlock = metaBlock;
      metaBlock = meta.nextMetaOffset;
    }

    // No free slot: allocate a new Meta block and chain it to the last one.
    final newMetaBlock = (await _allocateBlocks(1)).first;
    await _writeMeta(newMetaBlock, Meta.empty(_super));

    final lastMeta = await _readMeta(lastMetaBlock);
    await _writeMeta(
      lastMetaBlock,
      Meta(nextMetaOffset: newMetaBlock, entries: lastMeta.entries),
    );

    return (metaBlock: newMetaBlock, slot: 0);
  }

  /// Returns the set of all block indices currently in use (Meta chain blocks
  /// and data blocks referenced by live directory entries).
  Future<Set<int>> _usedBlocks() async {
    final used = <int>{0}; // block 0 is always the first Meta block
    int? metaBlock = 0;
    while (metaBlock != null) {
      final meta = await _readMeta(metaBlock);
      if (meta.nextMetaOffset != null) used.add(meta.nextMetaOffset!);
      for (final entry in meta.entries) {
        if (!entry.deleted) {
          for (final b in entry.blockIndices) {
            if (b != 0) used.add(b);
          }
        }
      }
      metaBlock = meta.nextMetaOffset;
    }
    return used;
  }

  /// Allocates [count] free data blocks, extending the container as needed.
  Future<List<int>> _allocateBlocks(int count) async {
    final used = await _usedBlocks();
    final allocated = <int>[];
    var candidate = 1;
    while (allocated.length < count) {
      if (!used.contains(candidate)) {
        allocated.add(candidate);
        used.add(candidate);
      }
      candidate++;
    }
    return allocated;
  }

  /// Returns the next available file ID (max existing + 1).
  Future<int> _nextFileId() async {
    final all = await _allEntries();
    if (all.isEmpty) return 1;
    final maxId = all
        .where((e) => !e.entry.deleted)
        .map((e) => e.entry.fileId)
        .fold(0, (max, id) => id > max ? id : max);
    return maxId + 1;
  }

  // ---------------------------------------------------------------------------
  // Public filesystem operations (used by _MicroFile / _MicroDirectory)
  // ---------------------------------------------------------------------------

  /// Reads the full contents of [filename].
  Future<Uint8List> readFile(String filename) async {
    final slot = await _findSlot(filename);
    if (slot == null) throw io.FileSystemException('File not found', filename);

    final meta = await _readMeta(slot.metaBlock);
    final entry = meta.entries[slot.slot];

    final buffer = BytesBuilder(copy: false);
    var remaining = entry.size;
    for (final blockIdx in entry.blockIndices) {
      if (blockIdx == 0 || remaining <= 0) break;
      final chunk = await _readBlock(blockIdx);
      final take = remaining < _super.blockSize ? remaining : _super.blockSize;
      buffer.add(chunk.sublist(0, take));
      remaining -= take;
    }
    return buffer.toBytes();
  }

  /// Writes [data] to [filename], replacing any existing content.
  Future<void> writeFile(String filename, Uint8List data) async {
    if (await _findSlot(filename) != null) await deleteFile(filename);

    if (data.length > _super.maxFileSize) {
      throw io.FileSystemException(
        'File size ${data.length} exceeds maximum ${_super.maxFileSize}',
        filename,
      );
    }

    // Acquire the directory slot BEFORE allocating data blocks so that any
    // newly-chained Meta block is already visible to _usedBlocks() when we
    // scan for free data blocks below.
    final slot = await _findOrAllocateFreeSlot();

    final blocksNeeded =
        data.isEmpty ? 0 : (data.length + _super.blockSize - 1) ~/ _super.blockSize;
    final blocks = blocksNeeded > 0 ? await _allocateBlocks(blocksNeeded) : <int>[];

    for (var i = 0; i < blocks.length; i++) {
      final start = i * _super.blockSize;
      final end = (start + _super.blockSize).clamp(0, data.length);
      final chunk = Uint8List(_super.blockSize);
      chunk.setAll(0, data.sublist(start, end));
      await _writeBlock(blocks[i], chunk);
    }

    final blockIndices = List<int>.filled(_super.maxBlocksPerFile, 0);
    for (var i = 0; i < blocks.length; i++) {
      blockIndices[i] = blocks[i];
    }

    final meta = await _readMeta(slot.metaBlock);
    final updatedEntries = List<DirectoryEntry>.from(meta.entries);
    updatedEntries[slot.slot] = DirectoryEntry(
      filename: filename,
      deleted: false,
      fileId: await _nextFileId(),
      size: data.length,
      blockIndices: blockIndices,
    );
    await _writeMeta(
      slot.metaBlock,
      Meta(nextMetaOffset: meta.nextMetaOffset, entries: updatedEntries),
    );
  }

  /// Marks the directory entry for [filename] as deleted.
  Future<void> deleteFile(String filename) async {
    final slot = await _findSlot(filename);
    if (slot == null) throw io.FileSystemException('File not found', filename);

    final meta = await _readMeta(slot.metaBlock);
    final entry = meta.entries[slot.slot];
    final updatedEntries = List<DirectoryEntry>.from(meta.entries);
    updatedEntries[slot.slot] = DirectoryEntry(
      filename: entry.filename,
      deleted: true,
      fileId: entry.fileId,
      size: entry.size,
      blockIndices: entry.blockIndices,
    );
    await _writeMeta(
      slot.metaBlock,
      Meta(nextMetaOffset: meta.nextMetaOffset, entries: updatedEntries),
    );
  }

  /// Returns the names of all live (non-deleted) files.
  Future<List<String>> listFiles() async {
    final all = await _allEntries();
    return all
        .where((e) => !e.entry.deleted && e.entry.filename.isNotEmpty)
        .map((e) => e.entry.filename)
        .toList();
  }

  /// Returns `true` if a live file with [filename] exists.
  Future<bool> fileExists(String filename) async =>
      await _findSlot(filename) != null;

  /// Returns the stored size of [filename] in bytes.
  Future<int> fileSize(String filename) async {
    final slot = await _findSlot(filename);
    if (slot == null) throw io.FileSystemException('File not found', filename);
    final meta = await _readMeta(slot.metaBlock);
    return meta.entries[slot.slot].size;
  }

  // ---------------------------------------------------------------------------
  // FileSystem interface
  // ---------------------------------------------------------------------------

  @override
  Directory get currentDirectory => _root;

  @override
  set currentDirectory(dynamic path) {
    final resolved = path is Directory ? path.path : path.toString();
    if (resolved != '/' && resolved.isNotEmpty) {
      throw UnsupportedError('changing current directory is not supported');
    }
  }

  @override
  Directory get systemTempDirectory => _root;

  @override
  bool get isWatchSupported => false;

  @override
  p.Context get path => p.posix;

  @override
  File file(dynamic path) => _MicroFile(this, _normalizePath(path.toString()));

  @override
  Directory directory(dynamic path) =>
      _MicroDirectory(this, _normalizePath(path.toString()));

  @override
  Link link(dynamic path) => _MicroLink(this, _normalizePath(path.toString()));

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
  Future<bool> isFile(String path) {
    final name = _normalizePath(path);
    final rel = name.startsWith('/') ? name.substring(1) : name;
    return fileExists(rel);
  }

  @override
  bool isFileSync(String path) =>
      throw UnsupportedError('sync operations are not supported');

  @override
  Future<bool> isDirectory(String path) async {
    final normalized = _normalizePath(path);
    if (normalized == '/') return true;
    final prefix = '${normalized.substring(1)}/';
    final files = await listFiles();
    return files.any((f) => f.startsWith(prefix));
  }

  @override
  bool isDirectorySync(String path) => _normalizePath(path) == '/';

  @override
  Future<bool> isLink(String path) => Future.value(false);

  @override
  bool isLinkSync(String path) => false;

  @override
  Future<FileSystemEntityType> type(String path, {bool followLinks = true}) async {
    final normalized = _normalizePath(path);
    if (normalized == '/') return FileSystemEntityType.directory;
    final rel = normalized.substring(1);
    if (await fileExists(rel)) return FileSystemEntityType.file;
    final prefix = '$rel/';
    final files = await listFiles();
    if (files.any((f) => f.startsWith(prefix))) return FileSystemEntityType.directory;
    return FileSystemEntityType.notFound;
  }

  @override
  FileSystemEntityType typeSync(String path, {bool followLinks = true}) =>
      throw UnsupportedError('sync operations are not supported');

  @override
  Future<FileStat> stat(String path) async {
    final normalized = _normalizePath(path);
    if (normalized == '/') return _root.stat();
    return _MicroFile(this, path).stat();
  }

  @override
  FileStat statSync(String path) =>
      throw UnsupportedError('sync operations are not supported');

  /// Normalises a path to start with `/`.
  String _normalizePath(String rawPath) {
    final trimmed = rawPath.trim();
    return trimmed.startsWith('/') ? trimmed : '/$trimmed';
  }
}
