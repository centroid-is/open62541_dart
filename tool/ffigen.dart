import 'dart:io';
import 'dart:core';

import 'package:ffigen/ffigen.dart';
import 'package:logging/logging.dart';

void main(){
  final packageRoot = Platform.script.resolve('../');
  final functions = Functions(
    include: Declarations.includeSet(
      {
      '__UA_Client_AsyncService',
      '__UA_Server_addNode',
      '__UA_Server_write',
      'UA_StatusCode_name',
      'UA_Variant_new',
    }),
    rename:(declaration) {
      switch (declaration.originalName) {
        case '__UA_Client_AsyncService':
          return 'UA_Client_AsyncService';
        case '__UA_Server_addNode':
          return 'UA_Server_addNode';
        case '__UA_Server_write':
          return 'UA_Server_write_raw';
        default:
          return declaration.originalName;
      }
    },
  );

  final globals = Globals(
    include: Declarations.includeSet(
      {
        'UA_TYPES',
      }
    )
  );

  final macros = Macros(
    include: Declarations.includeSet(
      {
        'UA_OPEN62541_VER_MAJOR',
        'UA_OPEN62541_VER_MINOR',
        'UA_OPEN62541_VER_PATCH',
        'UA_OPEN62541_VER_LABEL',
        'UA_OPEN62541_VER_COMMIT',
        'UA_OPEN62541_VERSION',
        'UA_ACCESSLEVELMASK_*', //TODO: How can I do this wildcard?
        'UA_TYPES_COUNT'
      }
    ) 
  );

  // Define our generator
  final generator = FfiGenerator(
    headers: Headers(
      entryPoints: [
        packageRoot.resolve('third_party/open62541/open62541.h'),
      ],
    ),
    functions: functions,
    structs: Structs.includeSet(
      {
        'UA_ClientConfig',
        'UA_Variant',
        'UA_EnumDefinition',
        'UA_StructureDefinition'
      }
    ),
    typedefs: Typedefs.includeSet(
      {'UA_Byte'}
    ),
    globals: globals,
    macros: macros,
    enums: Enums.includeAll,
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
 */
'''
    )
  );
  generator.generate(
    logger: Logger('')..onRecord.listen((record) => print(record.message)),
  );
}