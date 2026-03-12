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
- Hard deletes — freed blocks are zeroed and reclaimed immediately.
- `MicroFsEngine` is now exported for low-level block access.

## 1.0.3

- Added missing directory methods.

## 1.0.2

- Added more functions to the command line utility.

## 1.0.1

- Added command line utility.

## 1.0.0

- Initial version.
