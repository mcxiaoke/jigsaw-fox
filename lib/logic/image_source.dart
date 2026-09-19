import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:image_picker/image_picker.dart';

import 'package:jigsawpuzzle/services/app_logger.dart';

/// 已废弃，项目不再内置 demo 静态样本图（统一走网络内容或用户本地自制）。
@Deprecated('项目不再内置 sample 图片资源')
const assetSamples = <String>[];

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
