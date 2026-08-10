// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility that Flutter provides. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:file_picker_writable_example/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows the file picker actions', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('File Picker Example'), findsOneWidget);
    expect(find.text('Open File Picker'), findsOneWidget);
    expect(find.text('Create New File'), findsOneWidget);
  });
}
