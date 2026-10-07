import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;

import 'cloud_egress_gate.dart';

/// `Image.network` opens its own `dart:io` connection and would bypass the
/// admission gate (a merchant logo fetch reveals the merchant). This provider
/// loads through [GatedHttpClient] instead, so while Cloud is OFF it never
/// leaves the device and the widget falls back to its local mark.
@immutable
class GatedNetworkImage extends ImageProvider<GatedNetworkImage> {
  const GatedNetworkImage(this.url);

  final String url;

  @override
  Future<GatedNetworkImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<GatedNetworkImage>(this);

  @override
  ImageStreamCompleter loadImage(
      GatedNetworkImage key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _load(decode),
      scale: 1.0,
      debugLabel: 'GatedNetworkImage',
    );
  }

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final client = GatedHttpClient();
    try {
      final response = await client.get(Uri.parse(url));
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        throw http.ClientException('image_http_${response.statusCode}');
      }
      return await decode(await ui.ImmutableBuffer.fromUint8List(response.bodyBytes));
    } finally {
      client.close();
    }
  }

  @override
  bool operator ==(Object other) =>
      other is GatedNetworkImage && other.url == url;

  @override
  int get hashCode => url.hashCode;
}
