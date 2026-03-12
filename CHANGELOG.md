## 2.1.0

**Improvements:**

- **File-over-file rename**: `File.rename()` (and `MicroFsEngine.renameEntry()`) now replaces an existing file at the destination path instead of throwing a `FileSystemException`. Renaming onto an existing directory or link still throws. The replacement uses a crash-safer sequence: a temp entry is written before the destination is overwritten, so the destination name always points to valid data after the first write completes.

- **Soft deletes**: Block data is no longer zeroed when a file, link, or directory entry is deleted. Blocks are reclaimed implicitly — `usedBlocks()` walks the live directory tree and any block not reachable from a live entry is considered free. This improves deletion performance, removes unnecessary I/O, and eliminates a latent corruption risk where a crash during rename could cause a surviving directory entry to reference zeroed blocks.

- **Crash-safe rename ordering**: For renames where the destination does not already exist, the destination entry is now written before the source entry is cleared. A crash between the two writes leaves the entry visible at both paths (a transient hard link) rather than losing the entry entirely.

## 2.0.0

Complete rewrite with a new block-based architecture.

**Breaking changes:**
- `MicroFileSystem.format()` no longer accepts `blockSize` or `maxBlocksPerFile` parameters — block size is fixed at 4096 bytes.
- Removed the flat `listFiles()`, `fileExists()`, `fileSize()`, `readFile()`, `writeFile()`, `deleteFile()` methods from `MicroFileSystem`. Use the standard `package:file` API (`fs.file(path)`, `fs.directory(path)`, etc.) instead.
- Container format is incompatible with 1.x containers.

**New features:**
- Real directory hierarchy — subdirectories are first-class block-based structures, not filename prefixes.
- Symbolic links fully supported via `fs.link(path)`.
- Path component names can each be up to 48 UTF-8 bytes; total path depth is unlimited (v1 was limited to 48 bytes for the entire stored path).
- Container size is `blockCount × 4096` bytes with no superblock overhead — smaller than v1 for equivalent data.
- Block-based storage — freed blocks are reclaimed implicitly via `usedBlocks()` scan.
- `MicroFsEngine` is now exported for low-level block access.

## 1.0.3

- Added missing directory methods.

## 1.0.2

- Added more functions to the command line utility.

## 1.0.1

- Added command line utility.

## 1.0.0

- Initial version.
