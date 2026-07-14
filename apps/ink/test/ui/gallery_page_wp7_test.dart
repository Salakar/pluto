import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/document/document_io.dart';
import 'package:paper_ink/src/model/gallery_model.dart';
import 'package:paper_ink/src/ui/gallery_page.dart';
import 'package:pluto_ui/pluto_ui.dart';

void main() {
  test('gallery date formatter emits stable compact metadata', () {
    expect(
      formatGalleryModifiedDate(DateTime(2026, 7, 11).millisecondsSinceEpoch),
      '11 Jul 2026',
    );
  });

  testWidgets('gallery renders wordmark, actions, and artwork cards', (
    WidgetTester tester,
  ) async {
    final _WidgetGalleryOperations operations = _WidgetGalleryOperations(
      entries: <GalleryEntry>[_entry('a', name: 'harbor study')],
    );

    await _pumpGallery(tester, operations: operations);

    expect(find.text('Ink'), findsOneWidget);
    expect(find.text('settings'), findsOneWidget);
    expect(find.text('import'), findsOneWidget);
    expect(find.text('harbor study'), findsOneWidget);
    expect(find.text('new artwork'), findsOneWidget);
  });

  testWidgets('tapping an artwork invokes the editor route hook', (
    WidgetTester tester,
  ) async {
    String? openedId;
    final _WidgetGalleryOperations operations = _WidgetGalleryOperations(
      entries: <GalleryEntry>[_entry('a')],
    );

    await _pumpGallery(
      tester,
      operations: operations,
      onOpenArtwork: (String id) => openedId = id,
    );
    await tester.tap(find.byKey(const ValueKey<String>('artwork-a')));
    await tester.pump(const Duration(milliseconds: 100));

    expect(openedId, 'a');
  });

  testWidgets('empty gallery shows drawn easel and new-artwork action', (
    WidgetTester tester,
  ) async {
    await _pumpGallery(tester, operations: _WidgetGalleryOperations());

    expect(find.text('the easel is empty'), findsOneWidget);
    expect(find.widgetWithText(PaperButton, 'new artwork'), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);
  });

  testWidgets('new artwork chooser commits the selected preset and opens it', (
    WidgetTester tester,
  ) async {
    String? openedId;
    final _WidgetGalleryOperations operations = _WidgetGalleryOperations();
    await _pumpGallery(
      tester,
      operations: operations,
      onOpenArtwork: (String id) => openedId = id,
    );

    await tester.tap(find.widgetWithText(PaperButton, 'new artwork'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey<String>('size-square')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.widgetWithText(PaperButton, 'create'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();

    expect(operations.createdSize?.preset, GalleryCanvasPreset.square);
    expect(openedId, 'created');
  });

  testWidgets('custom size chooser steppers change dimensions by 256', (
    WidgetTester tester,
  ) async {
    final _WidgetGalleryOperations operations = _WidgetGalleryOperations();
    await _pumpGallery(tester, operations: operations);

    await tester.tap(find.widgetWithText(PaperButton, 'new artwork'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey<String>('size-custom')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey<String>('width-increase')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.widgetWithText(PaperButton, 'create'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();

    expect(operations.createdSize?.width, 2304);
    expect(operations.createdSize?.height, 2048);
  });

  testWidgets(
    'long press opens rename duplicate export and held delete actions',
    (WidgetTester tester) async {
      final _WidgetGalleryOperations operations = _WidgetGalleryOperations(
        entries: <GalleryEntry>[_entry('a')],
      );
      await _pumpGallery(tester, operations: operations);

      await tester.longPress(find.byKey(const ValueKey<String>('artwork-a')));
      await tester.pump();

      expect(find.text('rename'), findsOneWidget);
      expect(find.text('duplicate'), findsOneWidget);
      expect(find.text('export'), findsOneWidget);
      expect(find.text('hold to move to trash'), findsOneWidget);
    },
  );

  testWidgets('duplicate context action inserts a copy', (
    WidgetTester tester,
  ) async {
    final _WidgetGalleryOperations operations = _WidgetGalleryOperations(
      entries: <GalleryEntry>[_entry('a', name: 'study')],
    );
    await _pumpGallery(tester, operations: operations);

    await tester.longPress(find.byKey(const ValueKey<String>('artwork-a')));
    await tester.pump();
    await tester.tap(find.widgetWithText(PaperButton, 'duplicate'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();

    expect(find.text('study copy'), findsOneWidget);
  });

  testWidgets('held delete moves artwork to the expandable trash row', (
    WidgetTester tester,
  ) async {
    final _WidgetGalleryOperations operations = _WidgetGalleryOperations(
      entries: <GalleryEntry>[_entry('a')],
    );
    await _pumpGallery(
      tester,
      operations: operations,
      deleteHoldDuration: const Duration(milliseconds: 30),
    );

    await tester.longPress(find.byKey(const ValueKey<String>('artwork-a')));
    await tester.pump();
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey<String>('delete-hold'))),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.up();
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey<String>('artwork-a')), findsNothing);
    expect(find.textContaining('trash (1)'), findsOneWidget);
  });

  testWidgets('import empty state names the USB drop path', (
    WidgetTester tester,
  ) async {
    await _pumpGallery(tester, operations: _WidgetGalleryOperations());

    await tester.tap(find.byKey(const ValueKey<String>('gallery-import')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();

    expect(find.textContaining('documents/imports over USB'), findsOneWidget);
  });

  testWidgets('pager swaps between static card pages', (
    WidgetTester tester,
  ) async {
    final _WidgetGalleryOperations operations = _WidgetGalleryOperations(
      entries: <GalleryEntry>[
        for (var index = 0; index < 7; index += 1)
          _entry('$index', name: 'piece $index'),
      ],
    );
    await _pumpGallery(tester, operations: operations);

    expect(find.text('piece 0'), findsOneWidget);
    expect(find.text('piece 6'), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey<String>('gallery-page-2-button')),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('piece 0'), findsNothing);
    expect(find.text('piece 6'), findsOneWidget);
  });

  testWidgets('expanded trash restores an artwork', (
    WidgetTester tester,
  ) async {
    final _WidgetGalleryOperations operations = _WidgetGalleryOperations(
      trash: <GalleryTrashEntry>[
        GalleryTrashEntry(
          entry: _entry('old', name: 'old sketch'),
          trashedAtMs: 5,
        ),
      ],
    );
    await _pumpGallery(tester, operations: operations);

    await tester.tap(find.byKey(const ValueKey<String>('trash-toggle')));
    await tester.pump();
    expect(find.text('old sketch'), findsOneWidget);
    await tester.tap(find.widgetWithText(PaperButton, 'restore'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();

    expect(find.byKey(const ValueKey<String>('artwork-old')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('trash-toggle')), findsNothing);
  });
}

Future<void> _pumpGallery(
  WidgetTester tester, {
  required _WidgetGalleryOperations operations,
  ValueChanged<String>? onOpenArtwork,
  Duration deleteHoldDuration = const Duration(seconds: 3),
}) async {
  tester.view.physicalSize = const Size(954, 1696);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final GalleryModel model = GalleryModel(operations: operations);
  await tester.pumpWidget(
    PaperTheme(
      data: const PaperThemeData(isColorPanel: true),
      child: WidgetsApp(
        color: const Color(0xffffffff),
        pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
            PaperPageRoute<T>(settings: settings, builder: builder),
        home: GalleryPage(
          model: model,
          onOpenArtwork: onOpenArtwork ?? (_) {},
          onSettings: () {},
          deleteHoldDuration: deleteHoldDuration,
        ),
      ),
    ),
  );
  await tester.pump();
}

GalleryEntry _entry(String id, {String? name}) => GalleryEntry(
  id: id,
  name: name ?? 'art $id',
  createdAtMs: DateTime(2026, 7, 10).millisecondsSinceEpoch,
  modifiedAtMs: DateTime(2026, 7, 11).millisecondsSinceEpoch,
);

final class _WidgetGalleryOperations implements GalleryOperations {
  _WidgetGalleryOperations({
    List<GalleryEntry> entries = const <GalleryEntry>[],
    List<GalleryTrashEntry> trash = const <GalleryTrashEntry>[],
  }) : entries = entries.toList(),
       trash = trash.toList();

  final List<GalleryEntry> entries;
  final List<GalleryTrashEntry> trash;
  GalleryArtworkSize? createdSize;

  @override
  Future<int> collectExpiredTrash(Duration maximumAge) async => 0;

  @override
  Future<GalleryEntry> createArtwork(GalleryArtworkSize size) async {
    createdSize = size;
    final GalleryEntry created = _entry('created', name: 'Untitled');
    entries.insert(0, created);
    return created;
  }

  @override
  Future<GalleryEntry> duplicateArtwork(String artworkId) async {
    final GalleryEntry original = entries.firstWhere(
      (GalleryEntry item) => item.id == artworkId,
    );
    final GalleryEntry copy = _entry(
      '$artworkId-copy',
      name: '${original.name} copy',
    );
    entries.insert(0, copy);
    return copy;
  }

  @override
  Future<void> ensureFirstRunSeed() async {}

  @override
  Future<void> exportArtwork(String artworkId) async {}

  @override
  Future<GalleryEntry?> importArtwork(GalleryImportCandidate candidate) async {
    final GalleryEntry imported = _entry('imported');
    entries.insert(0, imported);
    return imported;
  }

  @override
  Future<List<GalleryEntry>> loadEntries() async =>
      List<GalleryEntry>.of(entries);

  @override
  Future<List<GalleryTrashEntry>> loadTrash() async =>
      List<GalleryTrashEntry>.of(trash);

  @override
  Future<void> moveToTrash(String artworkId) async {
    final GalleryEntry moved = entries.removeAt(
      entries.indexWhere((GalleryEntry item) => item.id == artworkId),
    );
    trash.add(
      GalleryTrashEntry(
        entry: moved,
        trashedAtMs: DateTime(2026, 7, 11).millisecondsSinceEpoch,
      ),
    );
  }

  @override
  Future<GalleryEntry> renameArtwork(String artworkId, String name) async {
    final int index = entries.indexWhere(
      (GalleryEntry item) => item.id == artworkId,
    );
    final GalleryEntry renamed = _entry(artworkId, name: name);
    entries[index] = renamed;
    return renamed;
  }

  @override
  Future<GalleryEntry> restoreArtwork(String artworkId) async {
    final GalleryTrashEntry item = trash.removeAt(
      trash.indexWhere(
        (GalleryTrashEntry candidate) => candidate.entry.id == artworkId,
      ),
    );
    entries.insert(0, item.entry);
    return item.entry;
  }

  @override
  Future<List<GalleryImportCandidate>> scanImports() async =>
      const <GalleryImportCandidate>[];
}
