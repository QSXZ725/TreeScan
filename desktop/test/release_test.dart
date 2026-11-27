import 'package:flutter_test/flutter_test.dart';
import 'package:treescan_desktop/about.dart';

void main() {
  test('compares release numbers and offers the first release to previews', () {
    final release = GitHubRelease('0.1.0', Uri.https('github.com', '/'));
    expect(release.isNewerThan('0.1.0+3', preview: true), isTrue);
    expect(release.isNewerThan('0.1.0', preview: false), isFalse);
    expect(release.isNewerThan('0.1.1+1', preview: true), isFalse);
    expect(release.isNewerThan('0.0.99', preview: false), isTrue);
  });
}
