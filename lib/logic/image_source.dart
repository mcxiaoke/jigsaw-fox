import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image_picker/image_picker.dart';

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
    final file = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 90,
    );
    if (file == null) throw const UserCancelledException();
    return file.readAsBytes();
  }
}

class NetworkSource implements PuzzleSource {
  NetworkSource(this.url);
  final String url;

  @override
  Future<Uint8List> loadBytes() async {
    final response = await Dio().get<List<int>>(
      url,
      options: Options(responseType: ResponseType.bytes),
    );
    final data = response.data;
    if (data == null || data.isEmpty) {
      throw Exception('empty response: $url');
    }
    return Uint8List.fromList(data);
  }
}

class UserCancelledException implements Exception {
  const UserCancelledException();
}
