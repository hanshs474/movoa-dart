import 'dart:io';

import 'package:movoa/movoa.dart';

Future<void> main() async {
  final movoa = Movoa(); // reads MOVOA_API_KEY
  try {
    print(await movoa.generateVideo(
        'a lighthouse in a storm, waves crashing, distant thunder',
        options: {'duration': 6, 'aspect_ratio': '16:9'}));
  } on MovoaException catch (e) {
    stderr.writeln(e);
    exitCode = 1;
  } finally {
    movoa.close();
  }
}
