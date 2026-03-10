# MicroFS Repository Analysis

## 1. Project Overview

**Name:** microfs  
**Version:** 1.0.0  
**Description:** A Dart library that provides a CPM (CP/M-compatible) filesystem implementation  
**SDK Requirement:** Dart ^3.10.7  
**Status:** Initial version (just released)

### Key Purpose
This is a **specialized filesystem library** that implements a CP/M-style file storage format. It allows you to:
- Create and mount virtual filesystems in a byte-stream container (e.g., a `RandomAccessFile`)
- Store files in a block-allocated format with metadata blocks (similar to CP/M disk format)
- Read/write files via an async API that implements Dart's `FileSystem` interface
- Support file operations: create, read, write, delete, rename, copy, list

---

## 2. Dependencies & Configuration

### pubspec.yaml Details
```yaml
dependencies:
  file: ^7.0.0          # For FileSystem abstraction (from package:file)
  path: ^1.9.0          # For path parsing/manipulation

dev_dependencies:
  lints: ^6.0.0         # Dart linting (recommended rules)
  test: ^1.25.6         # Test framework
```

### Analysis Configuration
- **analysis_options.yaml:** Uses `package:lints/recommended.yaml` (standard Dart recommended lints)
- **No custom rules:** Comments show available customization options but none are active
- **Standard Dart practices enforced:** camelCase types, consistent style

---

## 3. Directory & File Structure

```
/Users/james/Workspace/microfs/
├── lib/
│   ├── microfs.dart              # Public entry point (re-exports cpmfs.dart)
│   └── src/
│       └── cpmfs.dart            # Main implementation (968 lines)
├── test/
│   ├── cpmfs_test.dart           # Test suite (572 lines, 49 tests)
│   └── memory_file.dart          # Test helper (10 lines)
├── example/
│   └── microfs_example.dart      # Example usage
├── pubspec.yaml
├── pubspec.lock
├── analysis_options.yaml
├── CHANGELOG.md
├── README.md
└── [build artifacts: .dart_tool, .idea, microfs.iml]
```

### Key Observations:
- **Single source file:** All logic is in `lib/src/cpmfs.dart`
- **Flat namespace:** Only one public module exported from `lib/microfs.dart`
- **No .github directory:** No CI/CD workflows
- **No AI config files:** No CLAUDE.md, AGENTS.md, .cursorrules, etc.
- **README is template:** Not yet filled with real documentation
- **CHANGELOG:** Only version 1.0.0 (initial release)

---

## 4. Core Architecture & Key Classes

### Data Structure Classes (Serializable)

#### **Super** (lines 9-39)
- **Purpose:** Filesystem superblock (metadata about the whole container)
- **Fields:**
  - `blockSize` (uint32): Size of each block in bytes
  - `maxBlocksPerFile` (uint32): Maximum blocks per file
- **Derived:** `maxFileSize` = blockSize × maxBlocksPerFile
- **Fixed size:** 8 bytes (serialized)
- **Methods:** `toBytes()`, `fromBytes()`

#### **DirectoryEntry** (lines 114-216)
- **Purpose:** Single file metadata entry
- **Fields:**
  - `filename` (48 bytes UTF-8): File name
  - `deleted` (1 bit): Is entry marked deleted
  - `fileId` (uint32): Unique file identifier
  - `size` (uint64): Logical file size in bytes
  - `blockIndices` (N × uint32): List of block indices occupied by file
- **Fixed size:** `48 + 1 + 4 + 8 + (maxBlocksPerFile × 4)` bytes
- **Methods:** `toBytes()`, `fromBytes()`, `empty()` factory

#### **Meta** (lines 41-112)
- **Purpose:** Directory metadata block (stores multiple entries)
- **Fields:**
  - `nextMetaOffset` (int64 | null): Index of next Meta block in chain (for overflow)
  - `entries` (List): Fixed-capacity list of DirectoryEntry (immutable)
- **Capacity:** `(blockSize - 8) / DirectoryEntry.fixedByteSize`
- **Size:** Exactly `blockSize` bytes (padded)
- **Methods:** `toBytes()`, `fromBytes()`, `empty()` factory

### Filesystem Implementation Classes

#### **_CpmFile** (lines 269-442)
- **Purpose:** Implements Dart's `File` interface for CPM files
- **Parent:** Implements `File` interface from `package:file`
- **Key Methods:**
  - **Async (supported):** `exists()`, `stat()`, `length()`, `create()`, `delete()`, `rename()`, `copy()`
  - **Async read/write:** `readAsBytes()`, `readAsString()`, `readAsLines()`, `writeAsBytes()`, `writeAsString()`
  - **Streaming:** `openRead()` returns Stream
  - **Unsupported:** All `*Sync()` methods throw; `openWrite()`, `open()` (RandomAccessFile), file watching
- **Internal:** Uses `_name` to extract basename for storage in CPM container

#### **_CpmDirectory** (lines 448-525)
- **Purpose:** Implements Dart's `Directory` interface; flat root-only filesystem
- **Always represents:** Root directory `/`
- **Key Methods:**
  - `list()`: Returns Stream of all files as `_CpmFile` objects
  - `childFile(basename)`: Creates file reference
  - Child directories/symlinks: **Not supported** (throw UnsupportedError)
- **Properties:** Path is always `/`

#### **_CpmLink** (lines 531-565)
- **Purpose:** Stub implementation; symlinks not supported
- **All operations:** Throw `UnsupportedError`
- **Returns false/notFound** for existence checks

#### **_CpmFileStat** (lines 222-263)
- **Purpose:** Implements Dart's `FileStat` interface
- **Fields:** type, mode, size, changed/modified/accessed times
- **Special:** `notFound` singleton for missing files
- **Methods:** `modeString()` for POSIX permission string format

#### **CPMFilesystem** (lines 571-968)
- **Purpose:** Main filesystem implementation; implements `FileSystem` interface
- **State:** Holds `_raf` (RandomAccessFile) and `_super` (filesystem metadata)
- **Root:** Single `_CpmDirectory` instance

##### Static Factory Methods:
- `format(raf, super)` — Creates new formatted filesystem
- `mount(raf)` — Mounts existing filesystem

##### Core Public Operations (lines 756-864):
- `readFile(filename)` → `Uint8List`
- `writeFile(filename, data)` — Replaces or creates
- `deleteFile(filename)` — Marks as deleted
- `listFiles()` → `List<String>`
- `fileExists(filename)` → `bool`
- `fileSize(filename)` → `int`

##### Low-Level Helpers (lines 605-639):
- `_readAt()`, `_writeAt()` — Position-based I/O
- `_blockOffset()` — Convert block index to byte offset
- `_readMeta()`, `_writeMeta()` — Meta block serialization
- `_readBlock()`, `_writeBlock()` — Data block I/O

##### Filesystem Engine (lines 645-750):
- `_allEntries()` — Scan all Meta blocks
- `_findSlot()` — Locate file in directory chain
- `_findOrAllocateFreeSlot()` — Get/create directory slot
- `_usedBlocks()` — Find allocated blocks (for garbage detection)
- `_allocateBlocks()` — Allocate free blocks
- `_nextFileId()` — Generate unique file IDs

##### FileSystem Interface (lines 870-968):
- `currentDirectory`, `systemTempDirectory` → Always `/`
- `file()`, `directory()`, `link()` — Create file/dir/link references
- `isFile()`, `isDirectory()`, `isLink()` — Type checks
- `identical()`, `type()`, `stat()` — Path queries
- `_normalizePath()` — Ensure leading `/`

---

## 5. Async-First Design

### Key Pattern:
**All I/O operations are async `Future`-based.** There are NO synchronous (`*Sync`) methods implemented:
- All sync methods throw: `UnsupportedError('sync operations are not supported')`
- Streaming operations use `Stream.fromFuture()` to wrap async calls

### Import Context:
```dart
import 'dart:async';      // For Future, Stream, Completer
import 'dart:convert';    // UTF-8 encoding/decoding
import 'dart:io' as io;   // FileSystemException, FileMode, FileStat
import 'dart:typed_data'; // Uint8List, ByteData for binary I/O
import 'package:file/file.dart';  // File, Directory, FileSystem interfaces
import 'package:path/path.dart' as p;  // Path utilities
```

---

## 6. Test Suite Structure

**Framework:** `package:test` (dart:test)  
**Total Tests:** 49 tests organized in 8 groups  
**Location:** `/Users/james/Workspace/microfs/test/cpmfs_test.dart` (572 lines)

### Test Groups:

1. **Serialisation** (lines 22-88, ~7 tests)
   - Round-trip serialization: Super, DirectoryEntry, Meta
   - Data integrity checks
   - Flag preservation (e.g., deleted bit)

2. **format + mount** (lines 93-107, ~2 tests)
   - Filesystem creation and mounting
   - Empty listing verification
   - Super block read-back

3. **Core file operations** (lines 112-212, ~9 tests)
   - Write/read identity
   - File existence checks
   - File size queries
   - Empty file handling
   - File overwriting
   - File deletion (existence check post-delete)
   - Error cases (delete/read non-existent)
   - List filtering (live files only)
   - Multiple independent files

4. **Persistence across re-mount** (lines 214-271, ~3 tests)
   - Format, write data, mount again
   - Data survives the re-mount
   - File listing consistency

5. **Meta chain extension** (lines 273-320, ~2 tests)
   - Overflow when Meta block fills up
   - Automatic Meta block chaining
   - Slot allocation in chained blocks

6. **Slot reuse** (lines 322-340, ~2 tests)
   - Deleted entries can be reused
   - New files use deleted slots

7. **FileSystem interface** (lines 342-470, ~20 tests)
   - File interface: `exists()`, `stat()`, `length()`, CRUD operations
   - Directory interface: `list()`, `stat()`, `childFile()`
   - Link interface: stub operations
   - Unsupported features: `createTemp()`, `open()` (RandomAccessFile), file watching, subdirectories
   - Path normalization

8. **Container growth** (lines 472+, ~4 tests)
   - Writing files that span multiple blocks
   - Large files near max size
   - Block allocation stress

### Test Helper:
**memory_file.dart** (10 lines):
- `tempMemoryFile()` — Creates in-memory RandomAccessFile using `package:file/memory.dart`
- Used for all tests (no real disk I/O)

### Running Tests:
```bash
# Run all tests
dart test

# Run specific test group
dart test -n "Serialisation"

# Run specific test
dart test -n "write then read returns identical bytes"

# With verbose output
dart test -v
```

---

## 7. Example Usage

**File:** `/Users/james/Workspace/microfs/example/microfs_example.dart` (7 lines)
```dart
import 'package:microfs/microfs.dart';

void main() {
  var awesome = Awesome();
  print('awesome: ${awesome.isAwesome}');
}
```

**Status:** Template placeholder (references non-existent `Awesome` class)  
**Note:** Needs real examples once API is finalized

---

## 8. Public API Surface

### Exported Classes (from `lib/microfs.dart`):
- `Super` — Filesystem superblock
- `Meta` — Directory metadata block
- `DirectoryEntry` — File entry metadata
- `CPMFilesystem` — Main filesystem class

### Exported Interfaces:
- Implicitly: `File`, `Directory`, `FileSystem` (from `package:file`)

### Key Entry Points:
```dart
// Create new filesystem
final raf = RandomAccessFile(...);
final fs = await CPMFilesystem.format(raf, 
  Super(blockSize: 4096, maxBlocksPerFile: 8)
);

// Mount existing
final fs = await CPMFilesystem.mount(raf);

// File operations
await fs.writeFile('data.bin', Uint8List(...));
var bytes = await fs.readFile('data.bin');
await fs.deleteFile('data.bin');
var files = await fs.listFiles();

// Via FileSystem interface
var f = fs.file('myfile.txt');
await f.writeAsString('hello');
var content = await f.readAsString();

// Via Directory interface
var dir = fs.currentDirectory;
var entities = await dir.list().toList();
```

---

## 9. Limitations & Design Constraints

### Not Supported:
- **Subdirectories:** Flat namespace only; root directory `/` is the only valid path
- **Symbolic links:** Completely stubbed
- **Synchronous operations:** Only async `Future` API
- **File watching:** No `FileSystemEvent` support
- **RandomAccessFile:** No `open(mode: FileMode)` for manual seeking
- **Modification times:** Always returns epoch/current time (not stored)
- **Permissions:** Fixed POSIX modes (0644 files, 0755 dirs)
- **File renaming in place:** Rename = delete + write
- **Container shrinking:** Blocks are never reclaimed; deleted blocks are not reused for data

### Design Decisions:
1. **Immutable data structures:** `Meta.entries`, `DirectoryEntry.blockIndices` are unmodifiable lists
2. **All serialization in data classes:** `toBytes()` / `fromBytes()` are on the data classes, not in a separate serializer
3. **UTF-8 filenames:** Max 48 bytes (stored null-padded)
4. **Lazy sizing:** Container grows automatically as needed
5. **Flat block allocation:** Simple first-fit strategy; no fragmentation optimization
6. **Soft deletes:** Deleted entries stay in directory chain; not compacted

---

## 10. Code Style & Patterns

### Naming:
- **Private classes:** Prefix with `_` (e.g., `_CpmFile`, `_CpmDirectory`)
- **Public classes:** No prefix (e.g., `Super`, `CPMFilesystem`)
- **Final classes:** Used for immutable data (`final class Super`)
- **Methods:** Camel case; async methods have no prefix

### Constants:
- **Static const offsets/sizes:** Named with underscore (e.g., `_blockSizeOffset`)
- **Public const fields:** For well-known byte sizes (e.g., `Super.byteSize`)

### Error Handling:
- **FileSystemException** for I/O errors (file not found, size exceeded)
- **UnsupportedError** for not-implemented features
- **Assertions** for invariant checks (e.g., filename length)

### Async Pattern:
```dart
Future<Type> operation() async {
  // ... await calls
  return result;
}
```

### Binary Data Handling:
```dart
import 'dart:typed_data';

Uint8List bytes;
ByteData bd = ByteData.sublistView(bytes);
bd.setUint32(offset, value, Endian.little);
int value = bd.getUint32(offset, Endian.little);
```

---

## 11. Repository Maturity & Next Steps

### Current State:
- ✅ Core filesystem logic complete
- ✅ Comprehensive test coverage (49 tests)
- ❌ Documentation empty (README is template)
- ❌ No examples provided
- ❌ No CI/CD setup
- ❌ No copilot instructions
- ❌ Not published to pub.dev

### What Needs Writing:
1. **README.md:** Features, getting started, usage examples
2. **copilot-instructions.md:** Coding guidelines for AI assistants
3. **.github/workflows/:** CI tests, linting, code coverage
4. **Better examples:** Real-world usage in `example/`

---

## 12. Architecture Diagram (Text)

```
┌─────────────────────────────────────────┐
│  CPMFilesystem (FileSystem interface)   │
│  - mount(), format()                    │
│  - readFile(), writeFile(), deleteFile()│
│  - listFiles(), fileExists(), fileSize()│
└──────────┬────────────────────┬─────────┘
           │                    │
      ┌────▼────┐         ┌─────▼──────┐
      │ _CpmFile│         │_CpmDirectory│
      │(File)   │         │(Directory)  │
      └────┬────┘         └─────┬──────┘
           │                    │
      [Async ops]         [list() Stream]
      read/write          childFile()
      
┌──────────────────────────────────────────┐
│  Container File (RandomAccessFile)       │
├──────────────────────────────────────────┤
│  Super Block (8 bytes)                   │ (block offset 0)
├──────────────────────────────────────────┤
│  Block 0: Meta (directory metadata)      │
│  ├─ nextMetaOffset (int64)               │
│  └─ entries[0..N]: DirectoryEntry        │
├──────────────────────────────────────────┤
│  Block 1: Meta (overflow chain)          │
├──────────────────────────────────────────┤
│  Block N: Data (file content)            │
└──────────────────────────────────────────┘
```

---

## 13. Key Implementation Details

### Block Allocation Algorithm (lines 728-739):
1. Scan all Meta blocks to find used blocks
2. Iterate from block 1 upward
3. Allocate first N free blocks found
4. Container file grows automatically on write

### File Write Flow (lines 777-822):
1. If file exists, delete it (soft delete)
2. Check size limit
3. **Acquire directory slot first** (to update Meta chain visibility)
4. Allocate data blocks
5. Write data to blocks
6. Create DirectoryEntry with block indices
7. Update Meta block and flush

### File Read Flow (lines 757-774):
1. Find DirectoryEntry by filename
2. Iterate block indices
3. Read each block, concatenate up to `entry.size`
4. Return complete Uint8List

### Directory Chain Management (lines 678-704):
- Meta blocks can chain when full
- Linking: update previous Meta block's `nextMetaOffset`
- New Meta block initialized empty
- Slot search always walks the chain

---

## Summary for Copilot Instructions

**This is a specialized, mature filesystem library with:**
- Clean separation of concerns (serializable data vs. I/O implementations)
- Comprehensive test coverage
- Strict async-only API
- Well-documented binary format (via code comments)
- No external complexity; single-file implementation

**Key for AI assistants to know:**
1. All operations are **async** (no sync variants exist)
2. Filesystem is **flat** (no subdirectories)
3. Filenames are **UTF-8, max 48 bytes**
4. Files are **block-allocated** with a metadata chain
5. Deleted entries are **soft-deleted** (not compacted)
6. **No sync methods are supported** — this is by design
7. Tests use **in-memory filesystem** (MemoryFileSystem from package:file)
8. Data structures are **immutable** (final, unmodifiable lists)

