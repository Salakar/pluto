import 'package:flutter/widgets.dart';
import 'package:pluto_core/pluto_core.dart';

import 'paper_theme.dart';
import 'refresh.dart';

/// On-screen keyboard layer.
enum OskLayer {
  /// Lowercase letters.
  lowercase,

  /// Uppercase letters.
  uppercase,

  /// Numbers and common symbols.
  symbols,

  /// Extended punctuation.
  symbolsExtra,
}

/// E-ink on-screen keyboard with discrete key feedback.
final class PaperKeyboard extends StatefulWidget {
  /// Creates a paper keyboard.
  const PaperKeyboard({
    required this.onText,
    required this.onBackspace,
    required this.onSubmit,
    this.submitLabel = 'Done',
    this.initialLayer = OskLayer.lowercase,
    super.key,
  });

  /// Called with inserted text.
  final ValueChanged<String> onText;

  /// Called when backspace is pressed.
  final VoidCallback onBackspace;

  /// Called when submit is pressed.
  final VoidCallback onSubmit;

  /// Visible submit key label.
  final String submitLabel;

  /// Initial keyboard layer.
  final OskLayer initialLayer;

  @override
  State<PaperKeyboard> createState() => _PaperKeyboardState();
}

final class _PaperKeyboardState extends State<PaperKeyboard> {
  late OskLayer _layer = widget.initialLayer;

  List<List<_KeySpec>> get _rows {
    final _KeySpec shift = _KeySpec.action(
      'shift',
      isActive: _layer == OskLayer.uppercase,
    );
    final List<_KeySpec> bottomRow = <_KeySpec>[
      _KeySpec.action(
        _layer == OskLayer.lowercase || _layer == OskLayer.uppercase
            ? '123'
            : 'abc',
      ),
      const _KeySpec.text(','),
      const _KeySpec.space(),
      const _KeySpec.text('.'),
      _KeySpec.submit(widget.submitLabel),
    ];
    return switch (_layer) {
      OskLayer.lowercase => <List<_KeySpec>>[
        _keys('qwertyuiop'),
        _keys('asdfghjkl'),
        <_KeySpec>[shift, ..._keys('zxcvbnm'), const _KeySpec.backspace()],
        bottomRow,
      ],
      OskLayer.uppercase => <List<_KeySpec>>[
        _keys('QWERTYUIOP'),
        _keys('ASDFGHJKL'),
        <_KeySpec>[shift, ..._keys('ZXCVBNM'), const _KeySpec.backspace()],
        bottomRow,
      ],
      OskLayer.symbols => <List<_KeySpec>>[
        _keys('1234567890'),
        _keys('@#\$%&*()-'),
        <_KeySpec>[
          const _KeySpec.action('#+='),
          ..._keys(':/;!?'),
          const _KeySpec.backspace(),
        ],
        bottomRow,
      ],
      OskLayer.symbolsExtra => <List<_KeySpec>>[
        _keys('=+[]{}<>'),
        _keys('"\'\\|~^_`'),
        <_KeySpec>[
          const _KeySpec.action('123'),
          ..._keys(':/;!?'),
          const _KeySpec.backspace(),
        ],
        bottomRow,
      ],
    };
  }

  static List<_KeySpec> _keys(String characters) {
    return <_KeySpec>[
      for (int i = 0; i < characters.length; i++) _KeySpec.text(characters[i]),
    ];
  }

  void _handleKey(_KeySpec key) {
    EinkRefreshRegion.request(
      context,
      refreshClass: RefreshClass.fast,
      reason: 'keyboard.key',
    );
    switch (key.kind) {
      case _KeyKind.text:
        widget.onText(key.value);
      case _KeyKind.space:
        widget.onText(' ');
      case _KeyKind.backspace:
        widget.onBackspace();
      case _KeyKind.submit:
        widget.onSubmit();
      case _KeyKind.action:
        setState(() {
          _layer = switch (key.value) {
            'shift' =>
              _layer == OskLayer.uppercase
                  ? OskLayer.lowercase
                  : OskLayer.uppercase,
            'abc' => OskLayer.lowercase,
            '123' => OskLayer.symbols,
            '#+=' => OskLayer.symbolsExtra,
            _ => _layer,
          };
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return SizedBox(
      height: 280,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.palette.paper,
          border: Border(
            top: BorderSide(color: theme.palette.ink, width: PaperSpacing.rule),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            PaperSpacing.space8,
            PaperSpacing.space12,
            PaperSpacing.space8,
            PaperSpacing.space16,
          ),
          child: Column(
            children: <Widget>[
              for (final List<_KeySpec> row in _rows)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: <Widget>[
                        for (final _KeySpec key in row)
                          Expanded(
                            flex: key.flex,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 2,
                              ),
                              child: _KeyboardKey(
                                keySpec: key,
                                onPressed: () => _handleKey(key),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _KeyKind { text, space, backspace, submit, action }

final class _KeySpec {
  const _KeySpec._(this.kind, this.value, this.flex, {this.isActive = false});

  const _KeySpec.text(String value) : this._(_KeyKind.text, value, 1);

  const _KeySpec.space() : this._(_KeyKind.space, 'space', 4);

  const _KeySpec.backspace() : this._(_KeyKind.backspace, 'del', 2);

  const _KeySpec.submit(String value) : this._(_KeyKind.submit, value, 2);

  const _KeySpec.action(String value, {bool isActive = false})
    : this._(_KeyKind.action, value, 2, isActive: isActive);

  final _KeyKind kind;
  final String value;
  final int flex;

  /// Whether this action key represents an engaged mode (e.g. shift).
  final bool isActive;
}

final class _KeyboardKey extends StatefulWidget {
  const _KeyboardKey({required this.keySpec, required this.onPressed});

  final _KeySpec keySpec;
  final VoidCallback onPressed;

  @override
  State<_KeyboardKey> createState() => _KeyboardKeyState();
}

final class _KeyboardKeyState extends State<_KeyboardKey> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) {
      return;
    }
    setState(() {
      _pressed = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    final _KeySpec spec = widget.keySpec;
    // Submit and engaged modifiers render inverted so the commit action and
    // active state are unmistakable on a monochrome panel.
    final bool inverted =
        spec.kind == _KeyKind.submit ||
        (spec.kind == _KeyKind.action && spec.isActive);
    final bool showInk = _pressed ? inverted : !inverted;
    final Color background = showInk ? theme.palette.paper : theme.palette.ink;
    final Color foreground = showInk ? theme.palette.ink : theme.palette.paper;
    final bool isUtility =
        spec.kind == _KeyKind.action ||
        spec.kind == _KeyKind.backspace ||
        spec.kind == _KeyKind.space;
    final TextStyle style = isUtility
        ? theme.type.caption.copyWith(color: foreground)
        : theme.type.label.copyWith(color: foreground);
    return Semantics(
      button: true,
      label: spec.value,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _setPressed(true),
        onTapCancel: () => _setPressed(false),
        onTapUp: (_) {
          _setPressed(false);
          widget.onPressed();
        },
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: background,
            border: Border.all(
              color: theme.palette.ink,
              width: PaperSpacing.rule,
            ),
          ),
          child: Center(
            child: Text(
              spec.value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
        ),
      ),
    );
  }
}
