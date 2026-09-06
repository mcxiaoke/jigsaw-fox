import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image_picker/image_picker.dart';

import '../services/app_logger.dart';

const assetSamples = [
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

class NetworkSource implements PuzzleSource {
  NetworkSource(this.url);
  final String url;

  @override
  Future<Uint8List> loadBytes() async {
    Response<List<int>>? response;
    try {
      response = await Dio().get<List<int>>(
        url,
        options: Options(responseType: ResponseType.bytes),
      );
    } catch (e, st) {
      AppLogger.image.warning(
        'NetworkSource load fail url=${AppLogger.sanitizeUrl(url)}',
        e,
        st,
      );
      rethrow;
    }
    final data = response.data;
    if (data == null || data.isEmpty) {
      AppLogger.image.warning(
        'NetworkSource empty response url=${AppLogger.sanitizeUrl(url)}',
      );
      throw Exception('empty response: $url');
    }
    AppLogger.debug(
      AppLogger.image,
      'NetworkSource loaded bytes=${data.length} url=${AppLogger.sanitizeUrl(url)}',
    );
    return Uint8List.fromList(data);
  }
}

class UserCancelledException implements Exception {
  const UserCancelledException();
}
