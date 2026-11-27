import 'package:flutter/material.dart';

const mascotSource =
    'https://github.com/lokicorvus/crosspet/tree/'
    '6e98970f6ff9b44e8ac85215241cabcd78f67d92/characters/gpt';
const geminiMascotSource =
    'https://github.com/lokicorvus/crosspet/tree/'
    '6e98970f6ff9b44e8ac85215241cabcd78f67d92/characters/gemini';

enum MascotCharacter {
  gpt,
  gemini;

  String get idleAsset => switch (this) {
    gpt => 'assets/gpt-dragon-idle.webp',
    gemini => 'assets/gemini-idle.webp',
  };

  String get searchingAsset => switch (this) {
    gpt => 'assets/gpt-dragon-searching.webp',
    gemini => 'assets/gemini-searching.webp',
  };

  String get shortLabel => switch (this) {
    gpt => 'GPT',
    gemini => 'Gemini',
  };
}

class MascotPortrait extends StatelessWidget {
  const MascotPortrait({
    super.key,
    required this.size,
    this.searching = false,
    this.character = MascotCharacter.gpt,
  });

  final double size;
  final bool searching;
  final MascotCharacter character;

  @override
  Widget build(BuildContext context) {
    Widget portrait(String asset) => Image.asset(
      asset,
      width: size,
      height: size,
      alignment: Alignment.bottomCenter,
      fit: BoxFit.contain,
      cacheWidth: size <= 56 ? 144 : 288,
      excludeFromSemantics: true,
    );
    final child = SizedBox.square(
      dimension: size,
      child: AnimatedCrossFade(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 180),
        crossFadeState: searching
            ? CrossFadeState.showSecond
            : CrossFadeState.showFirst,
        firstChild: portrait(character.idleAsset),
        secondChild: portrait(character.searchingAsset),
      ),
    );
    final theme = Theme.of(context);
    if (theme.brightness != Brightness.dark || size < 40) return child;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(padding: EdgeInsets.all(size >= 80 ? 6 : 3), child: child),
    );
  }
}
