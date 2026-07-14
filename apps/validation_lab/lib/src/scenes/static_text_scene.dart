import 'package:flutter/widgets.dart';

import '../lab_style.dart';

const String _paragraph =
    'An e-ink panel holds its image without power, so the renderer only '
    'pays for the pixels it drives. Crisp text is the settle target: every '
    'glyph edge should land in a single high-quality pass, with no halo, '
    'no residual gray, and no drift between neighbouring lines. This block '
    'is intentionally dense so small-type contrast can be judged from '
    'camera footage at a fixed distance.';

const String _weightSample = 'Waveform ladder 0123456789';

const TextStyle _tinyStyle = TextStyle(
  fontFamily: 'Inter',
  fontFamilyFallback: <String>['Arial', 'Helvetica', 'sans-serif'],
  fontSize: 10,
  height: 1.4,
  fontWeight: FontWeight.w500,
  color: labInk,
);

/// Dense typographic page: settle quality and text clarity.
final class StaticTextScene extends StatelessWidget {
  /// Creates the static-text scene.
  const StaticTextScene({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        const SceneHeader(title: 'STATIC TEXT', purpose: 'SETTLE + CLARITY'),
        Expanded(
          child: ListView(
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.all(20),
            children: <Widget>[
              const Text(
                'Sphinx of black quartz, judge my vow.',
                style: labDisplayStyle,
              ),
              const SizedBox(height: 12),
              const Text(
                'Grayscale glyphs on glass, settled once.',
                style: labTitleStyle,
              ),
              const SizedBox(height: 16),
              Container(height: 3, color: labInk),
              const SizedBox(height: 16),
              const Text(
                'Heading 20/600 — edges, counters, and hairlines',
                style: labHeadingStyle,
              ),
              const SizedBox(height: 8),
              const Text(_paragraph, style: labBodyStyle),
              const SizedBox(height: 12),
              const Text(_paragraph, style: _tinyStyle),
              const SizedBox(height: 16),
              Container(height: 1, color: labInk),
              const SizedBox(height: 16),
              for (final FontWeight weight in <FontWeight>[
                FontWeight.w300,
                FontWeight.w400,
                FontWeight.w500,
                FontWeight.w600,
                FontWeight.w700,
                FontWeight.w900,
              ])
                Text(
                  '$_weightSample — ${weight.value}',
                  style: labBodyStyle.copyWith(fontWeight: weight),
                ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                color: labGrayLight,
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(r'$ pluto run --release', style: labMonoStyle),
                    Text(
                      r'$ ffmpeg -f avfoundation -i "0" scene.mov',
                      style: labMonoStyle,
                    ),
                    Text(
                      'mono 14/500 — code block on gray field',
                      style: labMonoStyle,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'CAPTION 12/600 — LETTER-SPACED ANNOTATION ROW',
                style: labCaptionStyle,
              ),
              const Text(
                'Label 14/600 — tile and button scale',
                style: labLabelStyle,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
