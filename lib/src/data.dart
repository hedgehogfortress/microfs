import 'dart:convert';
import 'dart:typed_data';

final class Super {
  static const int byteSize = 8;

  /// Byte offset of [blockSize] within the serialised Super.
  static const int _blockSizeOffset = 0;

  /// Byte offset of [maxBlocksPerFile] within the serialised Super.
  static const int _maxBlocksPerFileOffset = 4;

  final int blockSize;
  final int maxBlocksPerFile;

  const Super({required this.blockSize, required this.maxBlocksPerFile});

  int get maxFileSize => blockSize * maxBlocksPerFile;

  Uint8List toBytes() {
    final bd = ByteData(byteSize);
    bd.setUint32(_blockSizeOffset, blockSize, Endian.little);
    bd.setUint32(_maxBlocksPerFileOffset, maxBlocksPerFile, Endian.little);
    return bd.buffer.asUint8List();
  }

  factory Super.fromBytes(Uint8List bytes) {
    final bd = ByteData.sublistView(bytes, 0, byteSize);
    return Super(
      blockSize: bd.getUint32(_blockSizeOffset, Endian.little),
      maxBlocksPerFile: bd.getUint32(_maxBlocksPerFileOffset, Endian.little),
    );
  }
}

final class Meta {
  /// Byte size of the Meta header on disk (stores the next-block index as int64).
  static const int headerByteSize = 8;

  /// Sentinel value written to the next-block field when there is no next block.
  static const int _noNextBlock = -1;

  /// How many [DirectoryEntry] slots fit in one block after the Meta header.
  static int entriesCapacity(Super s) =>
      (s.blockSize - headerByteSize) ~/ DirectoryEntry.fixedByteSize(s);

  /// Block index of the next Meta block in the chain; `null` = end of chain.
  final int? nextMetaOffset;

  /// Fixed-capacity list of directory entry slots for this Meta block.
  /// Always exactly [entriesCapacity] entries long.
  final List<DirectoryEntry> entries;

  const Meta({required this.nextMetaOffset, required this.entries});

  /// Creates an empty Meta block sized for [s], with all slots set to default
  /// (empty, non-deleted) [DirectoryEntry] values.
  factory Meta.empty(Super s) {
    final capacity = entriesCapacity(s);
    return Meta(
      nextMetaOffset: null,
      entries: List.generate(
        capacity,
        (_) => DirectoryEntry.empty(s),
        growable: false,
      ),
    );
  }

  /// Serialises to exactly [s.blockSize] bytes, zero-padded.
  Uint8List toBytes(Super s) {
    final header = ByteData(headerByteSize);
    header.setInt64(0, nextMetaOffset ?? _noNextBlock, Endian.little);

    final builder = BytesBuilder(copy: false);
    builder.add(header.buffer.asUint8List());
    for (final entry in entries) {
      builder.add(entry.toBytes(s));
    }

    final data = builder.toBytes();
    final padded = Uint8List(s.blockSize);
    padded.setAll(0, data.take(s.blockSize));
    return padded;
  }

  factory Meta.fromBytes(Uint8List bytes, Super s) {
    final bd = ByteData.sublistView(bytes);
    final nextRaw = bd.getInt64(0, Endian.little);
    final nextMetaOffset = nextRaw == _noNextBlock ? null : nextRaw;

    final capacity = entriesCapacity(s);
    final entrySize = DirectoryEntry.fixedByteSize(s);
    final entries = List.generate(capacity, (i) {
      final start = headerByteSize + i * entrySize;
      return DirectoryEntry.fromBytes(
        Uint8List.sublistView(bytes, start, start + entrySize),
        s,
      );
    }, growable: false);

    return Meta(
      nextMetaOffset: nextMetaOffset,
      entries: List.unmodifiable(entries),
    );
  }
}

final class DirectoryEntry {
  /// Maximum byte length of [filename] when serialised (UTF-8, null-padded).
  static const int maxFilenameLength = 48;

  // ---- Serialised field sizes (bytes) ----------------------------------------
  static const int _flagsByteSize = 1;
  static const int _fileIdByteSize = 4;
  static const int _sizeFieldByteSize = 8;
  static const int _blockIndexByteSize = 4;

  // ---- Serialised field offsets (relative to start of entry) -----------------
  static const int _flagsOffset = maxFilenameLength;
  static const int _fileIdOffset = _flagsOffset + _flagsByteSize;
  static const int _sizeFieldOffset = _fileIdOffset + _fileIdByteSize;
  static const int _blockIndicesOffset = _sizeFieldOffset + _sizeFieldByteSize;

  /// Fixed serialised byte size for a [DirectoryEntry] given [s].
  ///
  /// Layout:
  ///   48  bytes  — filename (UTF-8, null-padded to maxFilenameLength)
  ///     1  byte   — flags (bit 0 = deleted)
  ///     4  bytes  — fileId (uint32 LE)
  ///     8  bytes  — size   (uint64 LE)
  ///  N × 4 bytes  — blockIndices (uint32 LE each), where N = s.maxBlocksPerFile
  static int fixedByteSize(Super s) =>
      _blockIndicesOffset + s.maxBlocksPerFile * _blockIndexByteSize;

  final String filename;

  /// Whether this entry has been marked as deleted.
  final bool deleted;

  final int fileId;

  /// Logical file size in bytes.
  final int size;

  /// Block indices occupied by this file.
  /// Always exactly [Super.maxBlocksPerFile] entries long; unused slots are `0`.
  final List<int> blockIndices;

  DirectoryEntry({
    required this.filename,
    required this.deleted,
    required this.fileId,
    required this.size,
    required this.blockIndices,
  }) : assert(
         filename.length <= maxFilenameLength,
         'filename exceeds maxFilenameLength ($maxFilenameLength)',
       );

  /// Creates a default empty (non-deleted, zero-sized) entry pre-sized for [s].
  factory DirectoryEntry.empty(Super s) => DirectoryEntry(
    filename: '',
    deleted: false,
    fileId: 0,
    size: 0,
    blockIndices: List.filled(s.maxBlocksPerFile, 0, growable: false),
  );

  Uint8List toBytes(Super s) {
    final byteCount = fixedByteSize(s);
    final bd = ByteData(byteCount);

    final encoded = utf8.encode(filename);
    for (var i = 0; i < maxFilenameLength; i++) {
      bd.setUint8(i, i < encoded.length ? encoded[i] : 0);
    }
    bd.setUint8(_flagsOffset, deleted ? 1 : 0);
    bd.setUint32(_fileIdOffset, fileId, Endian.little);
    bd.setUint64(_sizeFieldOffset, size, Endian.little);
    for (var i = 0; i < s.maxBlocksPerFile; i++) {
      bd.setUint32(_blockIndicesOffset + i * _blockIndexByteSize, blockIndices[i], Endian.little);
    }
    return bd.buffer.asUint8List();
  }

  factory DirectoryEntry.fromBytes(Uint8List bytes, Super s) {
    final bd = ByteData.sublistView(bytes);
    final filenameSlice = bytes.sublist(0, maxFilenameLength);
    final nullIdx = filenameSlice.indexOf(0);
    final filename = utf8.decode(
      nullIdx >= 0 ? filenameSlice.sublist(0, nullIdx) : filenameSlice,
      allowMalformed: true,
    );
    final deleted = (bd.getUint8(_flagsOffset) & 1) != 0;
    final fileId = bd.getUint32(_fileIdOffset, Endian.little);
    final size = bd.getUint64(_sizeFieldOffset, Endian.little);
    final blockIndices = List.generate(
      s.maxBlocksPerFile,
      (i) => bd.getUint32(_blockIndicesOffset + i * _blockIndexByteSize, Endian.little),
      growable: false,
    );
    return DirectoryEntry(
      filename: filename,
      deleted: deleted,
      fileId: fileId,
      size: size,
      blockIndices: blockIndices,
    );
  }
}
