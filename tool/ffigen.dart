import 'dart:io';
import 'dart:core';

import 'package:ffigen/ffigen.dart';
import 'package:logging/logging.dart';

void main(){
  final packageRoot = Platform.script.resolve('../');
  final generator = FfiGenerator(
    headers: Headers(
      entryPoints: [
        packageRoot.resolve('third_party/open62541/open62541.h'),
      ],
    ),
    functions: Functions.includeSet(
      {''}
    ),
    output: Output(
      dartFile: packageRoot.resolve('lib/src/third_party/open62541.g.dart'),
      preamble: '''
/*
 * Copyright (C) 2014-2021 the contributors as stated in the AUTHORS file
 *
 * This file is part of open62541. open62541 is free software: you can
 * redistribute it and/or modify it under the terms of the Mozilla Public
 * License v2.0 as stated in the LICENSE file provided with open62541.
 *
 * open62541 is distributed in the hope that it will be useful, but WITHOUT ANY
 * WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
 * A PARTICULAR PURPOSE.
 *
 * Sources can be found at
 * https://github.com/open62541/open62541
 * 
'''
    )
  );
  generator.generate(
    logger: Logger('')..onRecord.listen((record) => print(record.message)),
  );
}
/*
ffigen:
  output: lib/src/generated/open62541_bindings.dart
  name: open62541
  description: Low level bindings to open62541
  headers:
    entry-points:
      - 'open62541_build/open62541.h'
  functions:
    symbol-address:
      include:
        - 'UA_*' # Do this to expose all function pointers.
        - '__UA_Client_AsyncService'
        - '__UA_Server_addNode'
        - '__UA_Server_write'

    rename:
      '__UA_Client_AsyncService': 'UA_Client_AsyncService'
      '__UA_Server_addNode': 'UA_Server_addNode'
      '__UA_Server_write': 'UA_Server_write_raw'
  # UA_TYPES is a list inside the library and we need raw access
  # To the top level pointer to increment the list.
  globals:
    symbol-address:
      include:
        - 'UA_TYPES'
  compiler-opts:
    - '-Iopen62541_build/install/include/'
    - '-I/lib/clang/19/include/'
    - '-Wno-nullability-completeness'
    - '-Wno-expansion-to-defined'
    - '-DUA_ENABLE_ENCRYPTION' */