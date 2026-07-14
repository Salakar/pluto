import 'package:flutter/widgets.dart';

import '../lab_style.dart';

/// Static gray and color ramps: dithering quality and banding.
final class GradientRampsScene extends StatelessWidget {
  /// Creates the gradient-ramps scene.
  const GradientRampsScene({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        const SceneHeader(title: 'GRADIENT RAMPS', purpose: 'DITHER + BANDS'),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const _RampLabel('GRAY RAMP — SMOOTH HORIZONTAL'),
                const Expanded(
                  child: _RampBand(
                    gradient: LinearGradient(colors: <Color>[labInk, labPaper]),
                  ),
                ),
                const SizedBox(height: 10),
                const _RampLabel('GRAY STEPS — 16 QUANTIZED LEVELS'),
                Expanded(
                  child: Container(
                    decoration: const BoxDecoration(border: labHairlineBorder),
                    child: Row(
                      children: <Widget>[
                        for (int level = 0; level < 16; level += 1)
                          Expanded(
                            child: ColoredBox(
                              color: Color.fromARGB(
                                255,
                                level * 17,
                                level * 17,
                                level * 17,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                const _RampLabel('COLOR RAMPS — R / G / B THROUGH WHITE'),
                const Expanded(
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: _RampBand(
                          gradient: LinearGradient(
                            colors: <Color>[
                              labInk,
                              Color(0xFFFF0000),
                              labPaper,
                            ],
                          ),
                        ),
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: _RampBand(
                          gradient: LinearGradient(
                            colors: <Color>[
                              labInk,
                              Color(0xFF00FF00),
                              labPaper,
                            ],
                          ),
                        ),
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: _RampBand(
                          gradient: LinearGradient(
                            colors: <Color>[
                              labInk,
                              Color(0xFF0000FF),
                              labPaper,
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                const _RampLabel('VERTICAL — GRAY + HUE SWEEP'),
                const Expanded(
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: _RampBand(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: <Color>[labInk, labPaper],
                          ),
                        ),
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: _RampBand(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: <Color>[
                              Color(0xFFFF0000),
                              Color(0xFFFFFF00),
                              Color(0xFF00FF00),
                              Color(0xFF00FFFF),
                              Color(0xFF0000FF),
                              Color(0xFFFF00FF),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

final class _RampLabel extends StatelessWidget {
  const _RampLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(text, style: labCaptionStyle),
    );
  }
}

final class _RampBand extends StatelessWidget {
  const _RampBand({required this.gradient});

  final Gradient gradient;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(gradient: gradient, border: labHairlineBorder),
    );
  }
}
