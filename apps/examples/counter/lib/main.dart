import 'package:flutter/widgets.dart';

void main() {
  runApp(const CounterApp());
}

class CounterApp extends StatelessWidget {
  const CounterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return WidgetsApp(
      color: const Color(0xFFFFFFFF),
      debugShowCheckedModeBanner: false,
      pageRouteBuilder: _pageRouteBuilder,
      title: 'Counter',
      home: const _CounterScreen(),
    );
  }
}

PageRoute<T> _pageRouteBuilder<T>(
  RouteSettings settings,
  WidgetBuilder builder,
) {
  return PageRouteBuilder<T>(
    settings: settings,
    pageBuilder:
        (
          BuildContext context,
          Animation<double> animation,
          Animation<double> secondaryAnimation,
        ) {
          return builder(context);
        },
  );
}

class _CounterScreen extends StatefulWidget {
  const _CounterScreen();

  @override
  State<_CounterScreen> createState() => _CounterScreenState();
}

class _CounterScreenState extends State<_CounterScreen> {
  int _count = 0;

  void _increment() {
    setState(() {
      _count += 1;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: const Color(0xFFFFFFFF),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _increment,
          child: Center(
            child: Semantics(
              button: true,
              label: 'Increment counter',
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Text('Counter', style: _titleStyle),
                  const SizedBox(height: 28),
                  Text('$_count', style: _countStyle),
                  const SizedBox(height: 32),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.fromBorderSide(BorderSide(width: 2)),
                    ),
                    child: SizedBox(
                      width: 96,
                      height: 96,
                      child: Center(child: Text('+', style: _buttonStyle)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

const TextStyle _titleStyle = TextStyle(
  color: Color(0xFF111111),
  fontSize: 40,
  fontWeight: FontWeight.w600,
  height: 1.1,
);

const TextStyle _countStyle = TextStyle(
  color: Color(0xFF000000),
  fontSize: 132,
  fontWeight: FontWeight.w700,
  height: 1,
);

const TextStyle _buttonStyle = TextStyle(
  color: Color(0xFF000000),
  fontSize: 56,
  fontWeight: FontWeight.w500,
  height: 1,
);
