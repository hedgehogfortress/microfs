A minimal filesystem stored in a single binary container, implementing the
[`package:file`](https://pub.dev/packages/file) `FileSystem` interface. Files,
directories, and symbolic links are stored in fixed-size 4096-byte blocks inside
any `RandomAccessFile` — a local file, an in-memory buffer, or any other backing
store.

## Features

- Full directory hierarchy — create and nest directories to any depth
- Symbolic links via `fs.link(path)`
- Block-based allocation with automatic container growth
- Implements the `package:file` `FileSystem` interface — works with any code that accepts a `FileSystem`
- Fully async — backed by `RandomAccessFile`
- Portable containers: format once, mount anywhere
- `File.rename()` replaces an existing file at the destination (crash-safer four-step sequence)

## Getting started

Add to your `pubspec.yaml`:

```yaml
dependencies:
  microfs: ^2.1.0
  file: ^7.0.0
```

## Usage

### Format a new container

```dart
import 'dart:io' show FileMode;
import 'package:file/local.dart';
import 'package:microfs/microfs.dart';

final localFs = LocalFileSystem();
final raf = await localFs.file('data.bin').open(mode: FileMode.write);
final fs = await MicroFileSystem.format(raf);
```

### Write and read files

```dart
await fs.file('/notes.txt').writeAsString('Hello, microfs!');

final contents = await fs.file('/notes.txt').readAsString();
print(contents); // Hello, microfs!

final bytes = await fs.file('/image.png').readAsBytes();
```

### Directories

```dart
await fs.directory('/docs').create();
await fs.file('/docs/readme.txt').writeAsString('Welcome.');

// Recursive creation
await fs.file('/a/b/c.txt').writeAsString('deep', recursive: true);

// List root
await for (final entity in fs.directory('/').list()) {
  print(entity.path);
}
```

### Symbolic links

```dart
await fs.link('/latest').create('/docs/readme.txt');
print(await fs.link('/latest').target()); // /docs/readme.txt
```

### Rename / replace

```dart
// Move to a new name
await fs.file('/draft.txt').rename('/published.txt');

// Rename onto an existing file — replaces it
await fs.file('/new.txt').rename('/old.txt');
```

### Mount an existing container

```dart
final raf = await localFs.file('data.bin').open();
final fs = await MicroFileSystem.mount(raf);
```

## Limitations

- No synchronous API — sync methods throw `UnsupportedError`
- No file watching
- Path segments are UTF-8, max 48 bytes each
