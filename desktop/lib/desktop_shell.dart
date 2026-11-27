import 'dart:io';

/// Open a file, folder, or URL using the current desktop's default handler.
Future<void> openUnixDesktop(String path, {bool reveal = false}) async {
  final result = Platform.isMacOS
      ? await Process.run('/usr/bin/open', [if (reveal) '-R', path])
      : await Process.run('xdg-open', [
          if (reveal) File(path).parent.path else path,
        ]);
  if (result.exitCode != 0) {
    throw FileSystemException(result.stderr.toString().trim(), path);
  }
}
