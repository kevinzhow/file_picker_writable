import 'dart:async';
import 'dart:io';

import 'package:file_picker_writable/file_picker_writable.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _methodChannel = 'design.codeux.file_picker_writable';
const _eventChannel = 'design.codeux.file_picker_writable/events';
const _pathProviderChannel = 'plugins.flutter.io/path_provider';
const _codec = StandardMethodCodec();

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;

  setUpAll(() {
    messenger.setMockMessageHandler(
      _eventChannel,
      (message) async => _codec.encodeSuccessEnvelope(null),
    );
    // Initialize the singleton after the event channel has a test handler.
    FilePickerWritable();
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(
      const MethodChannel(_methodChannel),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel(_pathProviderChannel),
      null,
    );
  });

  test('external open handlers never delete the selected file', () async {
    final directory = await Directory.systemTemp.createTemp('picker-event-');
    addTearDown(() => directory.delete(recursive: true));
    final selectedFile = File('${directory.path}/selected.txt');
    await selectedFile.writeAsString('keep me');

    String? openedContent;
    Future<bool> handler(FileInfo info, File file) async {
      openedContent = await file.readAsString();
      return true;
    }

    messenger.setMockMethodCallHandler(
      const MethodChannel(_methodChannel),
      (call) async => null,
    );
    final state = FilePickerWritable().init();
    state.registerFileOpenHandler(handler);
    addTearDown(() => state.removeFileOpenHandler(handler));

    final response = Completer<ByteData?>();
    await messenger.handlePlatformMessage(
      _methodChannel,
      _codec.encodeMethodCall(
        MethodCall('openFile', <String, String>{
          'path': selectedFile.path,
          'identifier': 'bookmark',
          'persistable': 'true',
          'uri': selectedFile.uri.toString(),
          'fileName': 'selected.txt',
        }),
      ),
      response.complete,
    );
    _codec.decodeEnvelope((await response.future)!);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(openedContent, 'keep me');
    expect(await selectedFile.exists(), isTrue);
    expect(await selectedFile.readAsString(), 'keep me');
  });

  test('openFile passes picker options and reads the returned file', () async {
    final directory = await Directory.systemTemp.createTemp('picker-open-');
    addTearDown(() => directory.delete(recursive: true));
    final selectedFile = File('${directory.path}/selected.srt');
    await selectedFile.writeAsString('subtitle');
    final calls = <MethodCall>[];

    messenger.setMockMethodCallHandler(const MethodChannel(_methodChannel), (
      call,
    ) async {
      calls.add(call);
      if (call.method == 'openFilePicker') {
        return <String, String>{
          'path': selectedFile.path,
          'identifier': 'bookmark',
          'persistable': 'true',
          'uri': selectedFile.uri.toString(),
          'fileName': 'selected.srt',
        };
      }
      if (call.method == 'closeFileWithIdentifier') {
        return <String, String>{
          'path': selectedFile.path,
          'identifier': 'bookmark',
          'persistable': 'true',
          'uri': selectedFile.uri.toString(),
          'fileName': 'selected.srt',
        };
      }
      return null;
    });

    final content = await FilePickerWritable().openFile<String>(
      allowedExtensions: 'srt,vtt',
      reader: (info, file) => file.readAsString(),
    );
    await Future<void>.delayed(Duration.zero);

    expect(content, 'subtitle');
    expect(calls.first.method, 'openFilePicker');
    expect(calls.first.arguments, <String, String>{
      'allowedExtensions': 'srt,vtt',
    });
    expect(
      calls.any((call) => call.method == 'closeFileWithIdentifier'),
      isTrue,
    );
  });

  test(
    'openFileForCreate writes the proposed file before native save',
    () async {
      String? stagedContent;
      messenger.setMockMethodCallHandler(
        const MethodChannel(_pathProviderChannel),
        (call) async => Directory.systemTemp.path,
      );
      messenger.setMockMethodCallHandler(const MethodChannel(_methodChannel), (
        call,
      ) async {
        if (call.method != 'openFilePickerForCreate') {
          return null;
        }
        final arguments = (call.arguments as Map<Object?, Object?>)
            .cast<String, Object?>();
        final stagedFile = File(arguments['path']! as String);
        stagedContent = await stagedFile.readAsString();
        return <String, String>{
          'path': stagedFile.path,
          'identifier': 'created-bookmark',
          'persistable': 'true',
          'uri': Uri.file('/tmp/created.codeux').toString(),
          'fileName': 'created.codeux',
        };
      });

      final result = await FilePickerWritable().openFileForCreate(
        fileName: 'created.codeux',
        writer: (file) => file.writeAsString('new content'),
      );

      expect(stagedContent, 'new content');
      expect(result?.fileName, 'created.codeux');
    },
  );

  test(
    'picker cancellation returns null without invoking the reader',
    () async {
      messenger.setMockMethodCallHandler(
        const MethodChannel(_methodChannel),
        (call) async => null,
      );

      var readerCalled = false;
      final result = await FilePickerWritable().openFile<String>(
        reader: (info, file) async {
          readerCalled = true;
          return 'unexpected';
        },
      );

      expect(result, isNull);
      expect(readerCalled, isFalse);
    },
  );
}
