# Contributing to microfs

Contributions are welcome via pull requests on GitHub.

## Getting started

```bash
dart pub get
dart test
dart analyze
```

## Making changes

- Keep the public API surface minimal — `MicroFileSystem` is the only public export.
  Internal types (`Super`, `Meta`, `DirectoryEntry`) live in `lib/src/data.dart` and
  are imported directly by tests.
- The on-disk binary format is stable. Changes to serialisation offsets or field sizes
  in `lib/src/data.dart` are breaking changes and require a major version bump.
- All I/O must remain async. Sync methods may be added in future but should throw
  `UnsupportedError` until implemented.
- New features should include tests in `test/microfs_test.dart`.

## Submitting a pull request

1. Fork the repository and create a branch from `main`.
2. Make your changes and ensure `dart test` and `dart analyze` pass with no issues.
3. Open a pull request with a clear description of the change and why it's needed.

## Reporting issues

Please open a GitHub issue with a minimal reproduction case.
