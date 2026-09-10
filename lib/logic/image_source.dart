import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:image_picker/image_picker.dart';

import 'package:jigsawpuzzle/services/app_logger.dart';

const assetSamples = <String>[
  'assets/images/sample_01.jpg',
  'assets/images/sample_02.jpg',
  'assets/images/sample_03.jpg',
  'assets/images/sample_04.jpg',
  'assets/images/sample_05.jpg',
  'assets/images/sample_06.jpg',
  'assets/images/sample_07.jpg',
  'assets/images/sample_08.jpg',
  'assets/images/sample_09.jpg',
  'assets/images/sample_10.jpg',
];

// Used as an interface with multiple implementations.
// ignore: one_member_abstracts
abstract class PuzzleSource {
  Future<Uint8List> loadBytes();
}

class AssetSource implements PuzzleSource {
  AssetSource(this.assetPath);
  final String assetPath;

  @override
  Future<Uint8List> loadBytes() => rootBundle
      .load(assetPath)
      .then((b) => b.buffer.asUint8List(b.offsetInBytes, b.lengthInBytes));
}

class GallerySource implements PuzzleSource {
  @override
  Future<Uint8List> loadBytes() async {
    final picker = ImagePicker();
    XFile? file;
    try {
      file = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 90,
      );
    } catch (e, st) {
      AppLogger.image.warning('GallerySource pickImage failed', e, st);
      rethrow;
    }
    if (file == null) {
      AppLogger.debug(AppLogger.image, 'GallerySource user cancelled picker');
      throw const UserCancelledException();
    }
    return file.readAsBytes();
  }
}

class UserCancelledException implements Exception {
  const UserCancelledException();
}
