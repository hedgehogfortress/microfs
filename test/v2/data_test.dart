import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:microfs/v2/src/data.dart';

void main() {
  // ── Constants ──────────────────────────────────────────────────────────────
  group('Constants', () {
    test('blockSize is 4096', () => expect(blockSize, 4096));
    test('noBlock is 0xFFFFFFFF', () => expect(noBlock, 0xFFFFFFFF));
    test('rootBlockIndex is 0', () => expect(rootBlockIndex, 0));
    test('DirectoryEntry.byteSize is 61', () => expect(DirectoryEntry.byteSize, 61));
    test('DirectoryEntry.entriesPerBlock is 67', () => expect(DirectoryEntry.entriesPerBlock, 67));
    test('BlockListBlock.entriesCapacity is 1022', () => expect(BlockListBlock.entriesCapacity, 1022));
    test('DataBlock.dataSize is 4095', () => expect(DataBlock.dataSize, 4095));
    test('DirectoryBlock.entryCount is 67', () => expect(DirectoryBlock.entryCount, 67));
  });

  // ── DirectoryEntry ─────────────────────────────────────────────────────────
  group('DirectoryEntry serialisation', () {
    test('empty entry round-trips', () {
      final entry = DirectoryEntry.empty();
      final bytes = entry.toBytes();
      expect(bytes.length, DirectoryEntry.byteSize);

      final back = DirectoryEntry.fromBytes(bytes, 0);
      expect(back.type, entryTypeEmpty);
      expect(back.name, '');
      expect(back.size, 0);
      expect(back.blockIndex, noBlock);
    });

    test('file entry round-trips', () {
      const entry = DirectoryEntry(
        type: entryTypeFile,
        name: 'hello.txt',
        size: 12345,
        blockIndex: 42,
      );
      final bytes = entry.toBytes();
      final back = DirectoryEntry.fromBytes(bytes, 0);
      expect(back.type, entryTypeFile);
      expect(back.name, 'hello.txt');
      expect(back.size, 12345);
      expect(back.blockIndex, 42);
    });

    test('directory entry round-trips', () {
      const entry = DirectoryEntry(
        type: entryTypeDirectory,
        name: 'src',
        size: 0,
        blockIndex: 7,
      );
      final back = DirectoryEntry.fromBytes(entry.toBytes(), 0);
      expect(back.type, entryTypeDirectory);
      expect(back.name, 'src');
      expect(back.blockIndex, 7);
    });

    test('chain entry round-trips', () {
      // entryTypeChain no longer exists; this tests a plain directory entry
      // used as a folder pointer.
      const entry = DirectoryEntry(
        type: entryTypeDirectory,
        name: 'linked',
        size: 0,
        blockIndex: 99,
      );
      final back = DirectoryEntry.fromBytes(entry.toBytes(), 0);
      expect(back.type, entryTypeDirectory);
      expect(back.blockIndex, 99);
    });

    test('name is null-padded and truncated to 48 bytes', () {
      const entry = DirectoryEntry(
        type: entryTypeFile,
        name: 'short',
        size: 0,
        blockIndex: 1,
      );
      final bytes = entry.toBytes();
      // bytes 1..48 hold the name; bytes after 'short' (5 bytes) should be 0
      for (int i = 6; i <= 48; i++) {
        expect(bytes[i], 0, reason: 'byte $i should be 0 (null padding)');
      }
    });

    test('maximum filename length (48 bytes) round-trips', () {
      final longName = 'a' * 48;
      final entry = DirectoryEntry(
        type: entryTypeFile,
        name: longName,
        size: 0,
        blockIndex: 1,
      );
      final back = DirectoryEntry.fromBytes(entry.toBytes(), 0);
      expect(back.name, longName);
    });

    test('large size value round-trips', () {
      const entry = DirectoryEntry(
        type: entryTypeFile,
        name: 'big',
        size: 0xFFFFFFFFFFFFFFFF, // max uint64
        blockIndex: 1,
      );
      final back = DirectoryEntry.fromBytes(entry.toBytes(), 0);
      expect(back.size, 0xFFFFFFFFFFFFFFFF);
    });

    test('fromBytes respects offset', () {
      // Embed an entry at offset 10 in a larger buffer
      const entry = DirectoryEntry(
        type: entryTypeFile,
        name: 'offset',
        size: 77,
        blockIndex: 3,
      );
      final entryBytes = entry.toBytes();
      final buffer = Uint8List(10 + DirectoryEntry.byteSize);
      buffer.setRange(10, 10 + DirectoryEntry.byteSize, entryBytes);

      final back = DirectoryEntry.fromBytes(buffer, 10);
      expect(back.name, 'offset');
      expect(back.size, 77);
    });
  });

  // ── DirectoryBlock ─────────────────────────────────────────────────────────
  group('DirectoryBlock serialisation', () {
    test('empty block round-trips', () {
      final block = DirectoryBlock.empty();
      final bytes = block.toBytes();
      expect(bytes.length, blockSize);
      expect(bytes[0], blockTypeDirectory);

      final back = DirectoryBlock.fromBytes(bytes);
      expect(back.nextDirBlock, noBlock);
      expect(back.entries.length, DirectoryBlock.entryCount);
      for (final e in back.entries) {
        expect(e.type, entryTypeEmpty);
      }
    });

    test('block with mixed entries round-trips', () {
      final entries = List.generate(
        DirectoryBlock.entryCount,
        (i) => DirectoryEntry.empty(),
      );
      entries[0] = const DirectoryEntry(
        type: entryTypeFile,
        name: 'file.txt',
        size: 100,
        blockIndex: 5,
      );
      entries[1] = const DirectoryEntry(
        type: entryTypeDirectory,
        name: 'subdir',
        size: 0,
        blockIndex: 6,
      );

      final block = DirectoryBlock(nextDirBlock: 200, entries: entries);
      final back = DirectoryBlock.fromBytes(block.toBytes());

      expect(back.nextDirBlock, 200);
      expect(back.entries[0].name, 'file.txt');
      expect(back.entries[0].size, 100);
      expect(back.entries[1].type, entryTypeDirectory);
    });

    test('serialised bytes are exactly blockSize', () {
      expect(DirectoryBlock.empty().toBytes().length, blockSize);
    });

    test('nextDirBlock noBlock in empty block', () {
      expect(DirectoryBlock.empty().nextDirBlock, noBlock);
    });

    test('nextDirBlock chain pointer round-trips', () {
      final block = DirectoryBlock(
        nextDirBlock: 512,
        entries: List.generate(DirectoryBlock.entryCount, (_) => DirectoryEntry.empty()),
      );
      final back = DirectoryBlock.fromBytes(block.toBytes());
      expect(back.nextDirBlock, 512);
    });

    test('all 67 entry slots are readable', () {
      final entries = List<DirectoryEntry>.generate(
        DirectoryBlock.entryCount,
        (i) => DirectoryEntry(
          type: entryTypeFile,
          name: 'f$i',
          size: i,
          blockIndex: i + 1,
        ),
      );
      final back = DirectoryBlock.fromBytes(
        DirectoryBlock(nextDirBlock: noBlock, entries: entries).toBytes(),
      );
      for (int i = 0; i < DirectoryBlock.entryCount; i++) {
        expect(back.entries[i].name, 'f$i');
        expect(back.entries[i].size, i);
      }
    });
  });

  // ── BlockListBlock ─────────────────────────────────────────────────────────
  group('BlockListBlock serialisation', () {
    test('empty block round-trips', () {
      final block = BlockListBlock.empty();
      final bytes = block.toBytes();
      expect(bytes.length, blockSize);
      expect(bytes[0], blockTypeBlockList);

      final back = BlockListBlock.fromBytes(bytes);
      expect(back.nextBlockList, noBlock);
      expect(back.count, 0);
      expect(back.blockIndices.length, BlockListBlock.entriesCapacity);
      expect(back.blockIndices.every((v) => v == 0), isTrue);
    });

    test('block with entries round-trips', () {
      final indices = List.filled(BlockListBlock.entriesCapacity, 0);
      indices[0] = 10;
      indices[1] = 11;
      indices[2] = 12;

      final block = BlockListBlock(
        nextBlockList: noBlock,
        count: 3,
        blockIndices: indices,
      );
      final back = BlockListBlock.fromBytes(block.toBytes());
      expect(back.count, 3);
      expect(back.blockIndices[0], 10);
      expect(back.blockIndices[1], 11);
      expect(back.blockIndices[2], 12);
    });

    test('nextBlockList chain pointer round-trips', () {
      final indices = List.filled(BlockListBlock.entriesCapacity, 0);
      final block = BlockListBlock(
        nextBlockList: 999,
        count: 0,
        blockIndices: indices,
      );
      final back = BlockListBlock.fromBytes(block.toBytes());
      expect(back.nextBlockList, 999);
    });

    test('full capacity (1022 entries) round-trips', () {
      final indices = List.generate(BlockListBlock.entriesCapacity, (i) => i + 100);
      final block = BlockListBlock(
        nextBlockList: noBlock,
        count: BlockListBlock.entriesCapacity,
        blockIndices: indices,
      );
      final back = BlockListBlock.fromBytes(block.toBytes());
      expect(back.count, BlockListBlock.entriesCapacity);
      for (int i = 0; i < BlockListBlock.entriesCapacity; i++) {
        expect(back.blockIndices[i], i + 100);
      }
    });

    test('serialised bytes are exactly blockSize', () {
      expect(BlockListBlock.empty().toBytes().length, blockSize);
    });
  });

  // ── DataBlock ──────────────────────────────────────────────────────────────
  group('DataBlock serialisation', () {
    test('empty block round-trips', () {
      final block = DataBlock.empty();
      final bytes = block.toBytes();
      expect(bytes.length, blockSize);
      expect(bytes[0], blockTypeData);

      final back = DataBlock.fromBytes(bytes);
      expect(back.data.length, DataBlock.dataSize);
      expect(back.data.every((b) => b == 0), isTrue);
    });

    test('block with data round-trips', () {
      final payload = Uint8List(DataBlock.dataSize);
      for (int i = 0; i < payload.length; i++) {
        payload[i] = i % 256;
      }
      final block = DataBlock(data: payload);
      final back = DataBlock.fromBytes(block.toBytes());
      expect(back.data, payload);
    });

    test('partial data is zero-padded', () {
      final payload = Uint8List(DataBlock.dataSize);
      payload[0] = 0xAB;
      payload[1] = 0xCD;
      final block = DataBlock(data: payload);
      final bytes = block.toBytes();
      expect(bytes[1], 0xAB);
      expect(bytes[2], 0xCD);
      for (int i = 3; i < blockSize; i++) {
        expect(bytes[i], 0);
      }
    });

    test('serialised bytes are exactly blockSize', () {
      expect(DataBlock.empty().toBytes().length, blockSize);
    });
  });
}
