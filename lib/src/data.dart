import 'dart:convert';
import 'dart:typed_data';

// ── Constants ─────────────────────────────────────────────────────────────────

const int blockSize = 4096;

// Block type markers (byte 0 of every block)
const int blockTypeDirectory = 0x01;
const int blockTypeBlockList = 0x02;
const int blockTypeData = 0x03;

// Directory entry types
const int entryTypeEmpty = 0x00;
const int entryTypeFile = 0x01;
const int entryTypeDirectory = 0x02;
const int entryTypeLink = 0x04; // symbolic link; blockIndex → data block with UTF-8 target path

// Sentinel meaning "no block" for uint32 chain pointers
const int noBlock = 0xFFFFFFFF;

// Block 0 is always the root directory block
const int rootBlockIndex = 0;

// ── DirectoryEntry ────────────────────────────────────────────────────────────

/// One 61-byte slot within a [DirectoryBlock].
///
/// Layout:
/// ```
///   0     1  type        uint8
///   1    48  name        UTF-8, null-padded
///  49     8  size        uint64 LE (logical file size; target path length for links; 0 for dirs/empty)
///  57     4  blockIndex  uint32 LE (target block; noBlock for empty)
/// ```
final class DirectoryEntry {
  static const int maxNameBytes = 48;
  static const int byteSize = 1 + maxNameBytes + 8 + 4; // = 61
  // Header is 5 bytes (1 marker + 4 nextDirBlock), so:
  static const int entriesPerBlock = (blockSize - 5) ~/ byteSize; // = 67

  final int type;
  final String name;
  final int size;
  final int blockIndex;

  const DirectoryEntry({
    required this.type,
    required this.name,
    required this.size,
    required this.blockIndex,
  });

  factory DirectoryEntry.empty() => const DirectoryEntry(
    type: entryTypeEmpty,
    name: '',
    size: 0,
    blockIndex: noBlock,
  );

  Uint8List toBytes() {
    final bytes = Uint8List(byteSize);
    final bd = ByteData.sublistView(bytes);
    bytes[0] = type;

    final nameBytes = utf8.encode(name);
    final len = nameBytes.length.clamp(0, maxNameBytes);
    bytes.setRange(1, 1 + len, nameBytes);
    // remaining name bytes are already 0 (null-padded)

    bd.setUint64(49, size, Endian.little);
    bd.setUint32(57, blockIndex, Endian.little);
    return bytes;
  }

  factory DirectoryEntry.fromBytes(Uint8List bytes, int offset) {
    final bd = ByteData.sublistView(bytes, offset, offset + byteSize);
    final type = bytes[offset];

    // Find null terminator in name field
    int nameLen = 0;
    for (int i = 0; i < maxNameBytes; i++) {
      if (bytes[offset + 1 + i] == 0) break;
      nameLen++;
    }
    final name = nameLen > 0
        ? utf8.decode(bytes.sublist(offset + 1, offset + 1 + nameLen))
        : '';

    final size = bd.getUint64(49, Endian.little);
    final blockIndex = bd.getUint32(57, Endian.little);

    return DirectoryEntry(
      type: type,
      name: name,
      size: size,
      blockIndex: blockIndex,
    );
  }
}

// ── DirectoryBlock ────────────────────────────────────────────────────────────

/// A 4096-byte directory block.
///
/// Layout:
/// ```
///   0     1  type marker   (blockTypeDirectory = 0x01)
///   1     4  nextDirBlock  uint32 LE (noBlock = end of chain)
///   5  4087  entries       (67 × DirectoryEntry.byteSize)
/// 4092     4  padding       (zeroed)
/// ```
///
/// When all 67 entry slots are occupied and a new entry must be inserted,
/// a new [DirectoryBlock] is allocated and its index stored in [nextDirBlock].
final class DirectoryBlock {
  static const int headerSize = 5; // 1 marker + 4 nextDirBlock
  static const int entryCount = (blockSize - headerSize) ~/ DirectoryEntry.byteSize; // = 67
  // Padding: 4096 - 5 - (67 * 61) = 4 bytes

  final int nextDirBlock; // noBlock = no continuation
  final List<DirectoryEntry> entries; // always exactly entryCount entries

  DirectoryBlock({required this.nextDirBlock, required this.entries})
      : assert(entries.length == entryCount);

  factory DirectoryBlock.empty() => DirectoryBlock(
    nextDirBlock: noBlock,
    entries: List.generate(entryCount, (_) => DirectoryEntry.empty()),
  );

  Uint8List toBytes() {
    final bytes = Uint8List(blockSize);
    final bd = ByteData.sublistView(bytes);
    bytes[0] = blockTypeDirectory;
    bd.setUint32(1, nextDirBlock, Endian.little);
    int offset = headerSize;
    for (final entry in entries) {
      bytes.setRange(offset, offset + DirectoryEntry.byteSize, entry.toBytes());
      offset += DirectoryEntry.byteSize;
    }
    // remaining bytes are 0 (padding)
    return bytes;
  }

  factory DirectoryBlock.fromBytes(Uint8List bytes) {
    assert(bytes.length >= blockSize);
    assert(bytes[0] == blockTypeDirectory);
    final bd = ByteData.sublistView(bytes);
    final nextDirBlock = bd.getUint32(1, Endian.little);
    final entries = <DirectoryEntry>[];
    int offset = headerSize;
    for (int i = 0; i < entryCount; i++) {
      entries.add(DirectoryEntry.fromBytes(bytes, offset));
      offset += DirectoryEntry.byteSize;
    }
    return DirectoryBlock(nextDirBlock: nextDirBlock, entries: entries);
  }
}

// ── BlockListBlock ────────────────────────────────────────────────────────────

/// A 4096-byte blocklist block enumerating data blocks for a file.
///
/// Layout:
/// ```
///   0     1  type marker    (blockTypeBlockList = 0x02)
///   1     4  nextBlockList  uint32 LE (noBlock = end of chain)
///   5     2  count          uint16 LE (number of valid entries in blockIndices)
///   7  4089  blockIndices   (1022 × uint32 LE; unused slots = 0)
/// ```
///
/// Chain: if the file needs more than 1022 data blocks, allocate a new
/// [BlockListBlock] and set [nextBlockList] to its index.
final class BlockListBlock {
  static const int headerSize = 1 + 4 + 2; // = 7
  static const int entriesCapacity = (blockSize - headerSize) ~/ 4; // = 1022

  final int nextBlockList; // noBlock = no continuation
  final int count; // number of live entries
  final List<int> blockIndices; // always exactly entriesCapacity entries

  BlockListBlock({
    required this.nextBlockList,
    required this.count,
    required this.blockIndices,
  }) : assert(blockIndices.length == entriesCapacity);

  factory BlockListBlock.empty() => BlockListBlock(
    nextBlockList: noBlock,
    count: 0,
    blockIndices: List.filled(entriesCapacity, 0),
  );

  Uint8List toBytes() {
    final bytes = Uint8List(blockSize);
    final bd = ByteData.sublistView(bytes);
    bytes[0] = blockTypeBlockList;
    bd.setUint32(1, nextBlockList, Endian.little);
    bd.setUint16(5, count, Endian.little);
    for (int i = 0; i < entriesCapacity; i++) {
      bd.setUint32(headerSize + i * 4, blockIndices[i], Endian.little);
    }
    return bytes;
  }

  factory BlockListBlock.fromBytes(Uint8List bytes) {
    assert(bytes.length >= blockSize);
    assert(bytes[0] == blockTypeBlockList);
    final bd = ByteData.sublistView(bytes);
    final nextBlockList = bd.getUint32(1, Endian.little);
    final count = bd.getUint16(5, Endian.little);
    final blockIndices = List.generate(
      entriesCapacity,
      (i) => bd.getUint32(headerSize + i * 4, Endian.little),
    );
    return BlockListBlock(
      nextBlockList: nextBlockList,
      count: count,
      blockIndices: blockIndices,
    );
  }
}

// ── DataBlock ─────────────────────────────────────────────────────────────────

/// A 4096-byte data block holding raw file payload.
///
/// Layout:
/// ```
///   0     1  type marker  (blockTypeData = 0x03)
///   1  4095  data         (raw bytes; unused bytes zeroed)
/// ```
///
/// The logical file size is stored in the owning [DirectoryEntry], not here.
final class DataBlock {
  static const int dataSize = blockSize - 1; // = 4095

  final Uint8List data; // always exactly dataSize bytes

  DataBlock({required this.data}) : assert(data.length == dataSize);

  factory DataBlock.empty() =>
      DataBlock(data: Uint8List(dataSize));

  factory DataBlock.fromBytes(Uint8List bytes) {
    assert(bytes.length >= blockSize);
    assert(bytes[0] == blockTypeData);
    return DataBlock(data: Uint8List.fromList(bytes.sublist(1, blockSize)));
  }

  Uint8List toBytes() {
    final bytes = Uint8List(blockSize);
    bytes[0] = blockTypeData;
    bytes.setRange(1, blockSize, data);
    return bytes;
  }
}
