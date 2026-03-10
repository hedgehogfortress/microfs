# Copilot Instructions for microfs

## Project Overview

`microfs` is a pure Dart package that implements a CP/M-inspired block-based filesystem stored in a binary container (e.g., a file or memory buffer). It implements the `FileSystem` interface from `package:file`.

## Build, Test, and Lint

```bash
# Run all tests
dart test

# Run a single test by name substring
dart test -n "Serialisation"

# Run a single test file
dart test test/cpmfs_test.dart

# Analyze
dart analyze
```

## Architecture

All logic lives in two source files:
- `lib/src/data.dart` — `Super`, `Meta`, `DirectoryEntry` (internal serializable data types)
- `lib/src/filesystem.dart` — `MicroFileSystem` and private implementation classes

`lib/microfs.dart` exports only `MicroFileSystem` as the public API. The data classes are internal; tests import them directly via `package:microfs/src/data.dart`.

**Three conceptual layers inside the source files:**

1. **Serializable data classes** (`Super`, `DirectoryEntry`, `Meta`) — each handles its own binary serialization via `toBytes()` / `fromBytes()`. Offsets are hardcoded constants; changing these is a breaking format change.

2. **FileSystem implementation** (`MicroFileSystem`, `_MicroFile`, `_MicroDirectory`, `_MicroLink`) — implements the `package:file` interfaces. Only `MicroFileSystem` and `_MicroFile` have meaningful implementations; `_MicroDirectory` is a flat root-only directory, and `_MicroLink` always throws.

3. **Storage** — all reads/writes go through a `RandomAccessFile` (passed in at construction). Block allocation is simple first-fit; the container file grows automatically when more blocks are needed.

**Filesystem layout in the container:**
- Block 0: `Super` (filesystem metadata)
- Block 1+: Data blocks and `Meta` directory blocks interleaved

**Directory model:** Flat namespace — only `/` exists. `Meta` blocks hold `DirectoryEntry` records. When the initial `Meta` block is full, a new one is allocated and chained via `Meta.next`.

## Key Conventions

**Async-only (currently):** Every method that does I/O is `async`/`Future`-based. Synchronous variants (e.g., `readAsStringSync`) throw `UnsupportedError` — they haven't been implemented yet, not a permanent design constraint.

**Immutable data classes:** `Super`, `DirectoryEntry`, and `Meta` are declared `final class`. Update by creating new instances, not mutating.

**Soft deletes:** Deleted `DirectoryEntry` records stay in the `Meta` block with a `deleted` flag. Slot reuse: when writing a new file, the first deleted slot is reclaimed before allocating a new one.

**Error types:** Use `FileSystemException` for I/O and filesystem errors; use `UnsupportedError` for unimplemented features (links, sync ops, subdirectories, renaming, watching).

**Path handling:** All paths are normalized to start with `/`. Only POSIX paths are supported — no Windows-style separators.

**Filenames:** UTF-8, max 48 bytes. Path separators (`/`) are permitted within filenames — the limit applies to the full stored name including any separators.

## Testing Patterns

Tests use `package:test`. The helper `tempMemoryFile()` (defined in `test/memory_file.dart`) returns a `RandomAccessFile`-like in-memory file backed by `package:file`'s `MemoryFileSystem` — no disk I/O needed.

Typical test setup:
```dart
// Internal data types are imported directly from src/
import 'package:microfs/src/data.dart';

const stdSuper = Super(blockSize: 4096, maxBlocksPerFile: 8);
final raf = await tempMemoryFile();
final fs = await MicroFileSystem.format(raf, blockSize: stdSuper.blockSize, maxBlocksPerFile: stdSuper.maxBlocksPerFile);
```

Tests are grouped by feature area (Serialisation, format + mount, Core file operations, Persistence, Meta chain extension, Slot reuse, FileSystem interface, Container growth).
