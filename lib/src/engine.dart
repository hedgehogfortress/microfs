import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'data.dart';

/// Internal filesystem engine for microfs v2.
///
/// All paths are POSIX-style and normalized to start with `/`.
/// Block 0 is always the root [DirectoryBlock].
///
/// This class intentionally does not implement `package:file` interfaces — that
/// is the responsibility of the layer-3 wrapper.
final class MicroFsEngine {
  final io.RandomAccessFile _raf;

  MicroFsEngine._(this._raf);

  // ── Lifecycle ───────────────────────────────────────────────────────────────

  /// Creates a new, empty filesystem in [raf].
  /// Writes a single empty [DirectoryBlock] at block 0.
  static Future<MicroFsEngine> format(io.RandomAccessFile raf) async {
    final engine = MicroFsEngine._(raf);
    await engine.writeDirectoryBlock(rootBlockIndex, DirectoryBlock.empty());
    return engine;
  }

  /// Mounts an existing filesystem from [raf].
  /// Validates that block 0 is a directory block.
  static Future<MicroFsEngine> mount(io.RandomAccessFile raf) async {
    final engine = MicroFsEngine._(raf);
    final raw = await engine._readRawBlock(rootBlockIndex);
    if (raw[0] != blockTypeDirectory) {
      throw io.FileSystemException(
        'Invalid microfs v2 container: block 0 is not a directory block',
      );
    }
    return engine;
  }

  // ── Low-level block I/O ─────────────────────────────────────────────────────

  int _blockOffset(int index) => index * blockSize;

  Future<Uint8List> _readRawBlock(int index) async {
    await _raf.setPosition(_blockOffset(index));
    final bytes = await _raf.read(blockSize);
    if (bytes.length < blockSize) {
      // Block is beyond end of file — return zero-filled block
      final padded = Uint8List(blockSize);
      padded.setRange(0, bytes.length, bytes);
      return padded;
    }
    return bytes;
  }

  Future<void> _writeRawBlock(int index, Uint8List bytes) async {
    assert(bytes.length == blockSize);
    await _raf.setPosition(_blockOffset(index));
    await _raf.writeFrom(bytes);
  }

  Future<DirectoryBlock> readDirectoryBlock(int index) async {
    final raw = await _readRawBlock(index);
    return DirectoryBlock.fromBytes(raw);
  }

  Future<BlockListBlock> readBlockListBlock(int index) async {
    final raw = await _readRawBlock(index);
    return BlockListBlock.fromBytes(raw);
  }

  Future<DataBlock> readDataBlock(int index) async {
    final raw = await _readRawBlock(index);
    return DataBlock.fromBytes(raw);
  }

  Future<void> writeDirectoryBlock(int index, DirectoryBlock block) =>
      _writeRawBlock(index, block.toBytes());

  Future<void> writeBlockListBlock(int index, BlockListBlock block) =>
      _writeRawBlock(index, block.toBytes());

  Future<void> writeDataBlock(int index, DataBlock block) =>
      _writeRawBlock(index, block.toBytes());

  // ── Block allocation ────────────────────────────────────────────────────────

  /// Returns the set of all block indices reachable from the root directory.
  /// Used by [allocateBlock] to find free slots.
  Future<Set<int>> usedBlocks() async {
    final used = <int>{};
    await _collectUsed(rootBlockIndex, used);
    return used;
  }

  Future<void> _collectUsed(int dirBlockIndex, Set<int> used) async {
    if (used.contains(dirBlockIndex)) return;
    used.add(dirBlockIndex);

    final block = await readDirectoryBlock(dirBlockIndex);
    for (final entry in block.entries) {
      switch (entry.type) {
        case entryTypeDirectory:
          if (!used.contains(entry.blockIndex)) {
            await _collectUsed(entry.blockIndex, used);
          }
        case entryTypeFile:
        case entryTypeLink: // link target path stored identically to file data
          await _collectFileBlocks(entry.blockIndex, used);
      }
    }
    // Follow directory chain via the header field
    if (block.nextDirBlock != noBlock && !used.contains(block.nextDirBlock)) {
      await _collectUsed(block.nextDirBlock, used);
    }
  }

  Future<void> _collectFileBlocks(int startBlockIndex, Set<int> used) async {
    if (used.contains(startBlockIndex)) return;
    final raw = await _readRawBlock(startBlockIndex);
    used.add(startBlockIndex);

    if (raw[0] == blockTypeBlockList) {
      var blk = BlockListBlock.fromBytes(raw);
      while (true) {
        for (int i = 0; i < blk.count; i++) {
          used.add(blk.blockIndices[i]);
        }
        if (blk.nextBlockList == noBlock) break;
        used.add(blk.nextBlockList);
        blk = await readBlockListBlock(blk.nextBlockList);
      }
    }
    // If it's a data block, it was already added above.
  }

  /// Allocates one free block index (first-fit from 1).
  /// Grows the container file if necessary.
  ///
  /// [reserved] is an optional set of block indices that are considered
  /// already-in-use even if they haven't been linked into the directory tree
  /// yet (e.g., blocks allocated during the same write operation). The caller
  /// must add the returned index to [reserved] before making further calls.
  Future<int> allocateBlock([Set<int>? reserved]) async {
    final used = await usedBlocks();
    if (reserved != null) used.addAll(reserved);
    int candidate = 1;
    while (used.contains(candidate)) {
      candidate++;
    }
    // Ensure the container is large enough
    final requiredSize = _blockOffset(candidate + 1);
    final currentSize = await _raf.length();
    if (currentSize < requiredSize) {
      await _raf.setPosition(requiredSize - 1);
      await _raf.writeByte(0);
    }
    return candidate;
  }

  /// Frees all blocks in a file's storage chain rooted at [startBlockIndex].
  ///
  /// Since microfs v2 uses first-fit allocation (scanning usedBlocks), there
  /// is no explicit free-list to update — "freeing" a block simply means it
  /// will no longer appear in [usedBlocks] because no directory entry references
  /// it. This method zeroes the blocks so stale data is not misread.
  Future<void> _freeBlocks(int startBlockIndex) async {
    final raw = await _readRawBlock(startBlockIndex);
    final zeroed = Uint8List(blockSize);

    if (raw[0] == blockTypeBlockList) {
      var blk = BlockListBlock.fromBytes(raw);
      await _writeRawBlock(startBlockIndex, zeroed);
      while (true) {
        for (int i = 0; i < blk.count; i++) {
          await _writeRawBlock(blk.blockIndices[i], zeroed);
        }
        if (blk.nextBlockList == noBlock) break;
        final next = blk.nextBlockList;
        blk = await readBlockListBlock(next);
        await _writeRawBlock(next, zeroed);
      }
    } else {
      await _writeRawBlock(startBlockIndex, zeroed);
    }
  }

  // ── Directory traversal ─────────────────────────────────────────────────────

  /// Splits a normalized path into segments, ignoring empty parts.
  List<String> _segments(String path) =>
      path.split('/').where((s) => s.isNotEmpty).toList();

  String _normalizePath(String rawPath) {
    final normalized = p.posix.normalize(rawPath);
    return normalized.startsWith('/') ? normalized : '/$normalized';
  }

  /// Finds the [DirectoryEntry] for [name] within a directory block chain.
  /// Returns location info or null if not found.
  Future<({int dirBlock, int slot, DirectoryEntry entry})?> _findInDir(
    int dirBlockIndex,
    String name,
  ) async {
    int current = dirBlockIndex;
    while (current != noBlock) {
      final block = await readDirectoryBlock(current);
      for (int i = 0; i < DirectoryBlock.entryCount; i++) {
        final e = block.entries[i];
        if (e.type != entryTypeEmpty && e.name == name) {
          return (dirBlock: current, slot: i, entry: e);
        }
      }
      // Follow directory chain via the header field
      current = block.nextDirBlock;
    }
    return null;
  }

  /// Returns the block index of the directory at [path].
  /// Throws [FileSystemException] if any segment doesn't exist or isn't a directory.
  Future<int> _resolveDirBlock(String path) async {
    final segments = _segments(path);
    int current = rootBlockIndex;
    for (final seg in segments) {
      final found = await _findInDir(current, seg);
      if (found == null || found.entry.type != entryTypeDirectory) {
        throw io.FileSystemException('Directory not found', path);
      }
      current = found.entry.blockIndex;
    }
    return current;
  }

  /// Returns the [DirectoryEntry] for [path], or null if it doesn't exist.
  Future<DirectoryEntry?> _resolveEntry(String path) async {
    final segments = _segments(path);
    if (segments.isEmpty) return null; // root has no entry

    int current = rootBlockIndex;
    for (int i = 0; i < segments.length - 1; i++) {
      final found = await _findInDir(current, segments[i]);
      if (found == null || found.entry.type != entryTypeDirectory) return null;
      current = found.entry.blockIndex;
    }
    final found = await _findInDir(current, segments.last);
    return found?.entry;
  }

  /// Inserts [entry] into the directory block chain rooted at [dirBlockIndex].
  /// Finds the first empty slot; extends the chain if all slots are occupied.
  ///
  /// [reserved] is passed to [allocateBlock] when a new directory block is
  /// needed, ensuring in-flight allocations are not double-assigned.
  Future<void> _insertEntry(
    int dirBlockIndex,
    DirectoryEntry entry, [
    Set<int>? reserved,
  ]) async {
    int current = dirBlockIndex;
    while (true) {
      final block = await readDirectoryBlock(current);
      // Look for an empty slot across all entryCount slots
      for (int i = 0; i < DirectoryBlock.entryCount; i++) {
        if (block.entries[i].type == entryTypeEmpty) {
          final updated = List<DirectoryEntry>.from(block.entries);
          updated[i] = entry;
          await writeDirectoryBlock(
            current,
            DirectoryBlock(nextDirBlock: block.nextDirBlock, entries: updated),
          );
          return;
        }
      }
      // All slots occupied — follow or extend chain via the header field
      if (block.nextDirBlock != noBlock) {
        current = block.nextDirBlock;
        continue;
      }
      // Allocate a new directory block and link it
      final newDirIndex = await allocateBlock(reserved);
      reserved?.add(newDirIndex);
      await writeDirectoryBlock(newDirIndex, DirectoryBlock.empty());
      await writeDirectoryBlock(
        current,
        DirectoryBlock(nextDirBlock: newDirIndex, entries: block.entries),
      );
      current = newDirIndex;
    }
  }


  // ── File data I/O ────────────────────────────────────────────────────────────

  /// Reads [size] bytes of file data starting from [startBlockIndex].
  Future<Uint8List> _readFileData(int startBlockIndex, int size) async {
    final raw = await _readRawBlock(startBlockIndex);

    if (raw[0] == blockTypeData) {
      return Uint8List.fromList(raw.sublist(1, 1 + size));
    }

    if (raw[0] == blockTypeBlockList) {
      final result = Uint8List(size);
      int written = 0;
      var blk = BlockListBlock.fromBytes(raw);

      while (written < size) {
        for (int i = 0; i < blk.count && written < size; i++) {
          final dataRaw = await _readRawBlock(blk.blockIndices[i]);
          final chunk = DataBlock.fromBytes(dataRaw).data;
          final toCopy = (size - written).clamp(0, DataBlock.dataSize);
          result.setRange(written, written + toCopy, chunk);
          written += toCopy;
        }
        if (blk.nextBlockList == noBlock) break;
        blk = await readBlockListBlock(blk.nextBlockList);
      }
      return result;
    }

    throw io.FileSystemException(
      'Unexpected block type 0x${raw[0].toRadixString(16)} at block $startBlockIndex',
    );
  }

  /// Writes [data] to newly allocated blocks.
  /// Returns the index of the first block (data block or first blocklist block).
  ///
  /// [reserved] tracks all blocks allocated during this operation so that
  /// subsequent calls to [allocateBlock] within the same write don't
  /// double-assign them before any directory entry has been committed.
  Future<int> _writeFileData(Uint8List data, Set<int> reserved) async {
    if (data.length <= DataBlock.dataSize) {
      // Small file — single data block
      final blockData = Uint8List(DataBlock.dataSize);
      blockData.setRange(0, data.length, data);
      final idx = await allocateBlock(reserved);
      reserved.add(idx);
      await writeDataBlock(idx, DataBlock(data: blockData));
      return idx;
    }

    // Large file — allocate data blocks, then chain blocklists
    final int numDataBlocks =
        (data.length + DataBlock.dataSize - 1) ~/ DataBlock.dataSize;

    // Allocate all data blocks first
    final dataBlockIndices = <int>[];
    for (int i = 0; i < numDataBlocks; i++) {
      final idx = await allocateBlock(reserved);
      reserved.add(idx);
      final start = i * DataBlock.dataSize;
      final end = (start + DataBlock.dataSize).clamp(0, data.length);
      final chunk = Uint8List(DataBlock.dataSize);
      chunk.setRange(0, end - start, data.sublist(start, end));
      await writeDataBlock(idx, DataBlock(data: chunk));
      dataBlockIndices.add(idx);
    }

    // Build blocklist chain (1022 data blocks per blocklist block)
    // Process in reverse so we can chain forward pointers correctly.
    final blocklistStartIndices = <int>[];
    for (int start = 0;
        start < dataBlockIndices.length;
        start += BlockListBlock.entriesCapacity) {
      blocklistStartIndices.add(start);
    }

    int? nextBL;
    int firstBLIndex = -1;
    for (int bi = blocklistStartIndices.length - 1; bi >= 0; bi--) {
      final start = blocklistStartIndices[bi];
      final end = (start + BlockListBlock.entriesCapacity)
          .clamp(0, dataBlockIndices.length);
      final slice = dataBlockIndices.sublist(start, end);
      final entries = List<int>.filled(BlockListBlock.entriesCapacity, 0);
      for (int j = 0; j < slice.length; j++) {
        entries[j] = slice[j];
      }
      final blk = BlockListBlock(
        nextBlockList: nextBL ?? noBlock,
        count: slice.length,
        blockIndices: entries,
      );
      final blIdx = await allocateBlock(reserved);
      reserved.add(blIdx);
      await writeBlockListBlock(blIdx, blk);
      nextBL = blIdx;
      firstBLIndex = blIdx;
    }
    return firstBLIndex;
  }

  // ── Public path-based API ───────────────────────────────────────────────────

  /// Returns true if anything exists at [path] (file, directory, or link).
  Future<bool> exists(String path) async {
    path = _normalizePath(path);
    if (path == '/') return true;
    final entry = await _resolveEntry(path);
    return entry != null;
  }

  /// Returns true if [path] is a regular file.
  Future<bool> isFile(String path) async {
    path = _normalizePath(path);
    final entry = await _resolveEntry(path);
    return entry?.type == entryTypeFile;
  }

  /// Returns true if [path] is a directory.
  Future<bool> isDirectory(String path) async {
    path = _normalizePath(path);
    if (path == '/') return true;
    final entry = await _resolveEntry(path);
    return entry?.type == entryTypeDirectory;
  }

  /// Returns true if [path] is a symbolic link.
  Future<bool> isLink(String path) async {
    path = _normalizePath(path);
    final entry = await _resolveEntry(path);
    return entry?.type == entryTypeLink;
  }

  /// Returns the logical file size in bytes.
  /// Throws [FileSystemException] if [path] does not exist or is not a file.
  Future<int> fileSize(String path) async {
    path = _normalizePath(path);
    final entry = await _resolveEntry(path);
    if (entry == null || entry.type != entryTypeFile) {
      throw io.FileSystemException('Not a file', path);
    }
    return entry.size;
  }

  /// Returns all entries (files, subdirectories, and links) in the directory at [path].
  Future<List<DirectoryEntry>> listDirectory(String path) async {
    path = _normalizePath(path);
    final dirBlock = await _resolveDirBlock(path);

    final result = <DirectoryEntry>[];
    int current = dirBlock;
    while (current != noBlock) {
      final block = await readDirectoryBlock(current);
      for (final e in block.entries) {
        if (e.type == entryTypeFile ||
            e.type == entryTypeDirectory ||
            e.type == entryTypeLink) {
          result.add(e);
        }
      }
      current = block.nextDirBlock;
    }
    return result;
  }

  /// Reads the full contents of the file at [path].
  Future<Uint8List> readFile(String path) async {
    path = _normalizePath(path);
    final entry = await _resolveEntry(path);
    if (entry == null || entry.type != entryTypeFile) {
      throw io.FileSystemException('File not found', path);
    }
    if (entry.size == 0) return Uint8List(0);
    return _readFileData(entry.blockIndex, entry.size);
  }

  /// Writes [data] to [path], replacing any existing content.
  /// Creates parent directories if [recursive] is true; otherwise throws if
  /// the parent directory does not exist.
  Future<void> writeFile(
    String path,
    Uint8List data, {
    bool recursive = false,
  }) async {
    path = _normalizePath(path);
    final parentPath = p.posix.dirname(path);
    final name = p.posix.basename(path);

    // Ensure parent exists
    if (recursive) {
      await createDirectory(parentPath, recursive: true);
    }
    final parentDirBlock = await _resolveDirBlock(parentPath);

    // Hard delete existing file if present
    final existing = await _findInDir(parentDirBlock, name);
    if (existing != null) {
      if (existing.entry.type == entryTypeDirectory) {
        throw io.FileSystemException('Path is a directory', path);
      }
      await _freeBlocks(existing.entry.blockIndex);
      final block = await readDirectoryBlock(existing.dirBlock);
      final updated = List<DirectoryEntry>.from(block.entries);
      updated[existing.slot] = DirectoryEntry.empty();
      await writeDirectoryBlock(
        existing.dirBlock,
        DirectoryBlock(nextDirBlock: block.nextDirBlock, entries: updated),
      );
    }

    // Write data blocks, tracking all allocated block indices so that
    // _insertEntry's potential directory-chain extension doesn't collide.
    final reserved = <int>{};
    int startBlock;
    if (data.isEmpty) {
      startBlock = await allocateBlock(reserved);
      reserved.add(startBlock);
      await writeDataBlock(startBlock, DataBlock.empty());
    } else {
      startBlock = await _writeFileData(data, reserved);
    }

    // Insert directory entry (may allocate a new directory block if the
    // parent is full; reserved ensures no collision with file blocks).
    await _insertEntry(
      parentDirBlock,
      DirectoryEntry(
        type: entryTypeFile,
        name: name,
        size: data.length,
        blockIndex: startBlock,
      ),
      reserved,
    );
  }

  /// Deletes the file at [path] and reclaims all its blocks.
  /// Throws [FileSystemException] if [path] doesn't exist or is a directory.
  Future<void> deleteFile(String path) async {
    path = _normalizePath(path);
    final parentPath = p.posix.dirname(path);
    final name = p.posix.basename(path);
    final parentDirBlock = await _resolveDirBlock(parentPath);

    final found = await _findInDir(parentDirBlock, name);
    if (found == null || found.entry.type != entryTypeFile) {
      throw io.FileSystemException('File not found', path);
    }
    await _freeBlocks(found.entry.blockIndex);
    final block = await readDirectoryBlock(found.dirBlock);
    final updated = List<DirectoryEntry>.from(block.entries);
    updated[found.slot] = DirectoryEntry.empty();
    await writeDirectoryBlock(
      found.dirBlock,
      DirectoryBlock(nextDirBlock: block.nextDirBlock, entries: updated),
    );
  }

  // ── Link operations ──────────────────────────────────────────────────────────

  /// Reads and returns the raw target path of the symbolic link at [path].
  /// Does not resolve the target — call layer 3 for full resolution.
  /// Throws [FileSystemException] if [path] doesn't exist or is not a link.
  Future<String> readLink(String path) async {
    path = _normalizePath(path);
    final entry = await _resolveEntry(path);
    if (entry == null || entry.type != entryTypeLink) {
      throw io.FileSystemException('Not a link', path);
    }
    if (entry.size == 0) return '';
    final bytes = await _readFileData(entry.blockIndex, entry.size);
    return utf8.decode(bytes);
  }

  /// Creates a symbolic link at [path] pointing to [target].
  /// Throws [FileSystemException] if [path] already exists.
  Future<void> createLink(String path, String target) async {
    path = _normalizePath(path);
    final parentPath = p.posix.dirname(path);
    final name = p.posix.basename(path);
    final parentDirBlock = await _resolveDirBlock(parentPath);

    if (await _findInDir(parentDirBlock, name) != null) {
      throw io.FileSystemException('Already exists', path);
    }

    final targetBytes = Uint8List.fromList(utf8.encode(target));
    final reserved = <int>{};
    final startBlock = targetBytes.isEmpty
        ? await allocateBlock(reserved)
        : await _writeFileData(targetBytes, reserved);
    if (targetBytes.isEmpty) {
      reserved.add(startBlock);
      await writeDataBlock(startBlock, DataBlock.empty());
    }

    await _insertEntry(
      parentDirBlock,
      DirectoryEntry(
        type: entryTypeLink,
        name: name,
        size: targetBytes.length,
        blockIndex: startBlock,
      ),
      reserved,
    );
  }

  /// Updates the target of an existing symbolic link at [path] to [newTarget].
  /// Throws [FileSystemException] if [path] doesn't exist or is not a link.
  Future<void> updateLink(String path, String newTarget) async {
    path = _normalizePath(path);
    final parentPath = p.posix.dirname(path);
    final name = p.posix.basename(path);
    final parentDirBlock = await _resolveDirBlock(parentPath);

    final found = await _findInDir(parentDirBlock, name);
    if (found == null || found.entry.type != entryTypeLink) {
      throw io.FileSystemException('Not a link', path);
    }

    // Free old target blocks
    await _freeBlocks(found.entry.blockIndex);

    // Write new target
    final targetBytes = Uint8List.fromList(utf8.encode(newTarget));
    final reserved = <int>{};
    final startBlock = targetBytes.isEmpty
        ? await allocateBlock(reserved)
        : await _writeFileData(targetBytes, reserved);
    if (targetBytes.isEmpty) {
      reserved.add(startBlock);
      await writeDataBlock(startBlock, DataBlock.empty());
    }

    // Update directory entry in place
    final block = await readDirectoryBlock(found.dirBlock);
    final updated = List<DirectoryEntry>.from(block.entries);
    updated[found.slot] = DirectoryEntry(
      type: entryTypeLink,
      name: name,
      size: targetBytes.length,
      blockIndex: startBlock,
    );
    await writeDirectoryBlock(
      found.dirBlock,
      DirectoryBlock(nextDirBlock: block.nextDirBlock, entries: updated),
    );
  }

  /// Deletes the symbolic link at [path] and reclaims its storage.
  /// Throws [FileSystemException] if [path] doesn't exist or is not a link.
  Future<void> deleteLink(String path) async {
    path = _normalizePath(path);
    final parentPath = p.posix.dirname(path);
    final name = p.posix.basename(path);
    final parentDirBlock = await _resolveDirBlock(parentPath);

    final found = await _findInDir(parentDirBlock, name);
    if (found == null || found.entry.type != entryTypeLink) {
      throw io.FileSystemException('Link not found', path);
    }
    await _freeBlocks(found.entry.blockIndex);
    final block = await readDirectoryBlock(found.dirBlock);
    final updated = List<DirectoryEntry>.from(block.entries);
    updated[found.slot] = DirectoryEntry.empty();
    await writeDirectoryBlock(
      found.dirBlock,
      DirectoryBlock(nextDirBlock: block.nextDirBlock, entries: updated),
    );
  }

  /// Creates the directory at [path].
  /// If [recursive] is true, creates all intermediate directories as needed.
  Future<void> createDirectory(String path, {bool recursive = false}) async {
    path = _normalizePath(path);
    if (path == '/') return;

    final segments = _segments(path);
    int current = rootBlockIndex;

    for (int i = 0; i < segments.length; i++) {
      final seg = segments[i];
      final found = await _findInDir(current, seg);

      if (found != null) {
        if (found.entry.type != entryTypeDirectory) {
          throw io.FileSystemException(
            'Path component is not a directory',
            '/${segments.sublist(0, i + 1).join('/')}',
          );
        }
        current = found.entry.blockIndex;
        continue;
      }

      if (!recursive && i < segments.length - 1) {
        throw io.FileSystemException(
          'Parent directory does not exist',
          '/${segments.sublist(0, i + 1).join('/')}',
        );
      }

      // Allocate new directory block
      final newBlock = await allocateBlock();
      await writeDirectoryBlock(newBlock, DirectoryBlock.empty());

      await _insertEntry(
        current,
        DirectoryEntry(
          type: entryTypeDirectory,
          name: seg,
          size: 0,
          blockIndex: newBlock,
        ),
      );
      current = newBlock;
    }
  }

  /// Deletes the directory at [path].
  /// Throws if the directory is non-empty and [recursive] is false.
  Future<void> deleteDirectory(String path, {bool recursive = false}) async {
    path = _normalizePath(path);
    if (path == '/') {
      throw io.FileSystemException('Cannot delete root directory', path);
    }

    final parentPath = p.posix.dirname(path);
    final name = p.posix.basename(path);
    final parentDirBlock = await _resolveDirBlock(parentPath);

    final found = await _findInDir(parentDirBlock, name);
    if (found == null || found.entry.type != entryTypeDirectory) {
      throw io.FileSystemException('Directory not found', path);
    }

    final entries = await listDirectory(path);
    if (entries.isNotEmpty) {
      if (!recursive) {
        throw io.FileSystemException('Directory not empty', path);
      }
      // Recursively delete contents
      for (final e in entries) {
        final childPath = p.posix.join(path, e.name);
        if (e.type == entryTypeFile) {
          await deleteFile(childPath);
        } else if (e.type == entryTypeDirectory) {
          await deleteDirectory(childPath, recursive: true);
        } else if (e.type == entryTypeLink) {
          await deleteLink(childPath);
        }
      }
    }

    // Free the directory block chain
    await _freeDirBlocks(found.entry.blockIndex);

    // Remove entry from parent
    final block = await readDirectoryBlock(found.dirBlock);
    final updated = List<DirectoryEntry>.from(block.entries);
    updated[found.slot] = DirectoryEntry.empty();
    await writeDirectoryBlock(
      found.dirBlock,
      DirectoryBlock(nextDirBlock: block.nextDirBlock, entries: updated),
    );
  }

  /// Frees all blocks in a directory block chain (but NOT contents — caller
  /// must delete contents first).
  Future<void> _freeDirBlocks(int dirBlockIndex) async {
    final zeroed = Uint8List(blockSize);
    int current = dirBlockIndex;
    while (current != noBlock) {
      final block = await readDirectoryBlock(current);
      final next = block.nextDirBlock;
      await _writeRawBlock(current, zeroed);
      current = next;
    }
  }

  /// Copies the file at [src] to [dst].
  Future<void> copyFile(String src, String dst) async {
    final data = await readFile(src);
    await writeFile(dst, data);
  }

  /// Renames / moves the entry at [from] to [to].
  ///
  /// If [to] is an existing regular file it is atomically replaced using a
  /// four-step sequence that biases any crash toward preserving valid data at
  /// the destination name.  If [to] exists and is a directory or link, or if
  /// [from] is a directory or link and [to] exists, a [FileSystemException] is
  /// thrown.
  Future<void> renameEntry(String from, String to) async {
    from = _normalizePath(from);
    to = _normalizePath(to);
    if (from == to) return;

    final fromParentPath = p.posix.dirname(from);
    final fromName = p.posix.basename(from);
    final toParentPath = p.posix.dirname(to);
    final toName = p.posix.basename(to);

    final fromParentBlock = await _resolveDirBlock(fromParentPath);
    final found = await _findInDir(fromParentBlock, fromName);
    if (found == null) {
      throw io.FileSystemException('Source not found', from);
    }

    final toParentBlock = await _resolveDirBlock(toParentPath);
    final existingDest = await _findInDir(toParentBlock, toName);

    if (existingDest != null) {
      if (found.entry.type != entryTypeFile || existingDest.entry.type != entryTypeFile) {
        throw io.FileSystemException('Destination already exists', to);
      }

      // Four-step crash-safer file replacement.  After step 2 the destination
      // name always points to valid (source) content regardless of crashes.
      //
      //   1. Insert a temp entry in the destination's parent — a copy of the
      //      existing destination entry stored under a \x01-prefixed name.
      //      The SOH byte (0x01) cannot be produced by normal path operations
      //      and is not treated as a null terminator by the name serialiser.
      //   2. Overwrite the destination entry in place with the source's payload.
      //   3. Clear the source entry slot without freeing its blocks —
      //      destination now owns them.
      //   4. Locate the temp entry via _findInDir and free its blocks inline,
      //      avoiding any path-normalisation edge cases.
      const tempName = '\x01';

      // Step 1.
      await _insertEntry(
        toParentBlock,
        DirectoryEntry(
          type: existingDest.entry.type,
          name: tempName,
          size: existingDest.entry.size,
          blockIndex: existingDest.entry.blockIndex,
        ),
      );

      // Step 2. Re-read the block because _insertEntry may have written to it.
      final destBlock = await readDirectoryBlock(existingDest.dirBlock);
      final destUpdated = List<DirectoryEntry>.from(destBlock.entries);
      destUpdated[existingDest.slot] = DirectoryEntry(
        type: found.entry.type,
        name: toName,
        size: found.entry.size,
        blockIndex: found.entry.blockIndex,
      );
      await writeDirectoryBlock(
        existingDest.dirBlock,
        DirectoryBlock(nextDirBlock: destBlock.nextDirBlock, entries: destUpdated),
      );

      // Step 3. Clear source slot — do NOT call _freeBlocks, destination owns them.
      final srcBlock = await readDirectoryBlock(found.dirBlock);
      final srcUpdated = List<DirectoryEntry>.from(srcBlock.entries);
      srcUpdated[found.slot] = DirectoryEntry.empty();
      await writeDirectoryBlock(
        found.dirBlock,
        DirectoryBlock(nextDirBlock: srcBlock.nextDirBlock, entries: srcUpdated),
      );

      // Step 4. Free old destination blocks inline.  Re-resolve the parent
      // since _insertEntry may have extended the directory chain.
      final refreshedToParentBlock = await _resolveDirBlock(toParentPath);
      final tempFound = await _findInDir(refreshedToParentBlock, tempName);
      if (tempFound != null) {
        await _freeBlocks(tempFound.entry.blockIndex);
        final tempBlock = await readDirectoryBlock(tempFound.dirBlock);
        final tempUpdated = List<DirectoryEntry>.from(tempBlock.entries);
        tempUpdated[tempFound.slot] = DirectoryEntry.empty();
        await writeDirectoryBlock(
          tempFound.dirBlock,
          DirectoryBlock(nextDirBlock: tempBlock.nextDirBlock, entries: tempUpdated),
        );
      }
      return;
    }

    // Normal rename — destination does not exist.

    // Remove from old location.
    final fromBlock = await readDirectoryBlock(found.dirBlock);
    final fromUpdated = List<DirectoryEntry>.from(fromBlock.entries);
    fromUpdated[found.slot] = DirectoryEntry.empty();
    await writeDirectoryBlock(
      found.dirBlock,
      DirectoryBlock(nextDirBlock: fromBlock.nextDirBlock, entries: fromUpdated),
    );

    // Insert in new location with updated name.
    await _insertEntry(
      toParentBlock,
      DirectoryEntry(
        type: found.entry.type,
        name: toName,
        size: found.entry.size,
        blockIndex: found.entry.blockIndex,
      ),
    );
  }
}
