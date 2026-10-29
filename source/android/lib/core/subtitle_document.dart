import 'dart:io';

/// A single explicitly selected subtitle, owned until the player is disposed.
class SubtitleDocument {
  SubtitleDocument(
    this.path,
    this.title,
    this.codec,
    this._release, {
    this.language = '',
  });
  final String path, title, codec, language;
  final Future<void> Function() _release;
  Future<void>? _closing;
  File get file => File(path);
  Future<void> close() => _closing ??= _release();
}
