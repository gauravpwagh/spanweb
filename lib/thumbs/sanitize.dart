import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Turns downloaded bytes into a small, clean JPEG, or null if they aren't a
/// safe image. Decoding happens in pure Dart in a background isolate, so the
/// platform image decoder only ever sees images this app encoded itself.
Future<Uint8List?> sanitizeThumbnail(Uint8List bytes) =>
    Isolate.run(() => sanitizeThumbnailSync(bytes));

const maxSourceSide = 4096;
const thumbWidth = 480;

Uint8List? sanitizeThumbnailSync(Uint8List bytes) {
  try {
    final decoder = switch (img.findFormatForData(bytes)) {
      img.ImageFormat.jpg => img.JpegDecoder(),
      img.ImageFormat.png => img.PngDecoder(),
      img.ImageFormat.webp => img.WebPDecoder(),
      _ => null,
    };
    if (decoder == null) return null;
    // Check the size from the header before decoding, so a small file that
    // claims huge dimensions is never expanded in memory.
    final info = decoder.startDecode(bytes);
    if (info == null ||
        info.width <= 0 ||
        info.height <= 0 ||
        info.width > maxSourceSide ||
        info.height > maxSourceSide) {
      return null;
    }
    final frame = decoder.decodeFrame(0);
    if (frame == null) return null;
    final small = img.copyResize(
      frame,
      width: min(thumbWidth, frame.width),
      interpolation: img.Interpolation.average,
    );
    // Resizing copies metadata across, so clear it before encoding.
    small
      ..exif = img.ExifData()
      ..iccProfile = null
      ..textData = null;
    return img.encodeJpg(small, quality: 75);
  } on Object {
    return null;
  }
}
