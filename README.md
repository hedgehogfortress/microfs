<!-- 
This README describes the package. If you publish this package to pub.dev,
this README's contents appear on the landing page for your package.

For information about how to write a good package README, see the guide for
[writing package pages](https://dart.dev/tools/pub/writing-package-pages). 

For general information about developing packages, see the Dart guide for
[creating packages](https://dart.dev/guides/libraries/create-packages)
and the Flutter guide for
[developing packages and plugins](https://flutter.dev/to/develop-packages). 
-->

A minimal filesystem stored in a single binary container. Files are stored in
fixed-size blocks inside any `RandomAccessFile` — a local file, an in-memory
buffer, or any other backing store. The filesystem implements the
[`package:file`](https://pub.dev/packages/file) `FileSystem` interface, so it
works with any code that accepts a `FileSystem`.

## Features

- Stores a flat collection of files in a single binary container
- Block-based allocation with automatic container growth
- Implements the `package:file` `FileSystem` interface
- Fully async — backed by `RandomAccessFile`
- Containers are portable: format once, mount anywhere

## Getting started

Add to your `pubspec.yaml`:

```yaml
dependencies:
  microfs: ^1.0.0
  file: ^7.0.0
```

## Usage

### Format a new container

```dart
import 'package:file/local.dart';
import 'package:microfs/microfs.dart';

final localFs = LocalFileSystem();
final tempDir = await localFs.systemTempDirectory.createTemp('myapp_');
final raf = await tempDir.childFile('data.bin').open(mode: FileMode.write);

final fs = await MicroFileSystem.format(
  raf,
  blockSize: 4096,
  maxBlocksPerFile: 8,
);
```

### Write and read files

```dart
await fs.file('notes.txt').writeAsString('Hello, microfs!');

final contents = await fs.file('notes.txt').readAsString();
print(contents); // Hello, microfs!

final bytes = await fs.file('image.png').readAsBytes();
```

### List files

```dart
await for (final entity in fs.currentDirectory.list()) {
  print(entity.path);
}
```

### Mount an existing container

```dart
final raf = await localFs.file('data.bin').open();
final fs = await MicroFileSystem.mount(raf);
```

## Limitations

- Flat namespace only — no subdirectories
- No synchronous API (sync methods throw `UnsupportedError`)
- No symbolic links
- No file watching
- Filenames are UTF-8, max 48 bytes (path separators are permitted within that limit)

