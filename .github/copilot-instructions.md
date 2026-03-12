# Copilot Instructions for microfs

## Agent Rules

- **Never run `git commit`** or any command that creates a git commit (e.g. `git commit`, `git commit -m`, `git commit --amend`). Always leave committing to the user.

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
- `lib/src/data.dart` — `DirectoryEntry`, `DirectoryBlock`, `BlockListBlock`, `DataBlock` (internal serialisable data types)
- `lib/src/engine.dart` — `MicroFsEngine` (low-level block engine)
- `lib/src/filesystem.dart` — `MicroFileSystem`, `_MicroFile`, `_MicroDirectory`, `_MicroLink` (`package:file` wrappers)

`lib/microfs.dart` exports `MicroFileSystem` and `MicroFsEngine` as the public API. The data classes are internal; tests import them directly via `package:microfs/src/data.dart`.

**Three conceptual layers inside the source files:**

1. **Serialisable data classes** (`DirectoryEntry`, `DirectoryBlock`, `BlockListBlock`, `DataBlock`) — each handles its own binary serialisation via `toBytes()` / `fromBytes()`. Offsets are hardcoded constants; changing these is a breaking format change.

2. **Block engine** (`MicroFsEngine`) — low-level block I/O, block allocation (first-fit via `usedBlocks()` scan), directory traversal, and all file/link/directory CRUD. Does not implement `package:file` interfaces.

3. **FileSystem wrapper** (`MicroFileSystem`, `_MicroFile`, `_MicroDirectory`, `_MicroLink`) — implements the `package:file` interfaces on top of `MicroFsEngine`. Only `MicroFileSystem` and `_MicroFile` have meaningful implementations; `_MicroDirectory` is a flat root-only directory, and `_MicroLink` always throws.

**Filesystem layout in the container:**
- Block 0: root `DirectoryBlock`
- Block 1+: `DirectoryBlock` chain extensions, `BlockListBlock`s, and `DataBlock`s interleaved

**Block types** (byte 0 of every block):
- `0x01` `blockTypeDirectory` — directory block holding up to 67 `DirectoryEntry` slots
- `0x02` `blockTypeBlockList` — block-list block for large files (up to 1022 data-block pointers per block)
- `0x03` `blockTypeData` — raw file/link payload (4095 bytes of data per block)

**Directory model:** Each directory is a chain of `DirectoryBlock`s linked via `nextDirBlock`. Only `/` exists at the root; subdirectories are allocated `DirectoryBlock` chains of their own. Entries store `type`, `name` (UTF-8, up to 48 bytes), `size`, and `blockIndex`.

**Block allocation:** `allocateBlock()` calls `usedBlocks()` which walks the entire live directory tree collecting every referenced block index. Any index not in the resulting Set is free (first-fit from block 1). Deleted entries are cleared to `DirectoryEntry.empty()`; their blocks are reclaimed implicitly on the next `usedBlocks()` scan (soft delete — no zeroing).

## Key Conventions

**Async-only (currently):** Every method that does I/O is `async`/`Future`-based. Synchronous variants (e.g., `readAsStringSync`) throw `UnsupportedError` — they haven't been implemented yet, not a permanent design constraint.

**Immutable data classes:** `DirectoryEntry`, `DirectoryBlock`, `BlockListBlock`, and `DataBlock` are declared `final class`. Update by creating new instances, not mutating.

**Soft deletes:** Deleted `DirectoryEntry` slots are set to `DirectoryEntry.empty()` (`type == entryTypeEmpty`). Block data is never zeroed; blocks become free simply by no longer being reachable from any live directory entry. Slot reuse: `_insertEntry` scans for the first empty slot before extending the directory chain.

**Error types:** Use `FileSystemException` for I/O and filesystem errors; use `UnsupportedError` for unimplemented features (sync ops, watching).

**Path handling:** All paths are normalised to start with `/`. Only POSIX paths are supported — no Windows-style separators.

**Filenames:** UTF-8, max 48 bytes per path segment.

## Testing Patterns

Tests use `package:test`. The helper `tempMemoryFile()` (defined in `test/memory_file.dart`) returns a `RandomAccessFile`-like in-memory file backed by `package:file`'s `MemoryFileSystem` — no disk I/O needed.

Two test files:
- `test/engine_test.dart` — unit tests for `MicroFsEngine` directly
- `test/microfs_test.dart` — integration tests via the public `MicroFileSystem` / `package:file` API

Typical test setup:
```dart
// Internal data types are imported directly from src/
import 'package:microfs/src/data.dart';
import 'package:microfs/src/engine.dart';

Future<MicroFsEngine> freshEngine() async {
  final raf = await tempMemoryFile();
  return MicroFsEngine.format(raf);
}

// Or via the public API:
Future<MicroFileSystem> freshFs() async =>
    MicroFileSystem.format(await tempMemoryFile());
```

Tests are grouped by feature area (format + mount, exists / isFile / isDirectory, write + read file, delete file, copy + rename, renameEntry, directory chain extension, blocklist chaining, persistence across remount, usedBlocks, symbolic links).
