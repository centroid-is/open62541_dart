import 'dart:ffi';

import 'package:ffi/ffi.dart';

void main() {
  final ptr = calloc<Char>(1500);

  for (var i = 0; i < 1500; i++) {
    ptr.elementAt(i).value = 1;
  }

  var sum = 0;
  for (var i = 0; i < 1500; i++) {
    sum += ptr.elementAt(i).value;
  }
  print(sum);
}
