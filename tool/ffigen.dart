import 'dart:io';
import 'dart:core';

import 'package:ffigen/ffigen.dart';
import 'package:logging/logging.dart';

Future<void> main() async {
  final packageRoot = Platform.script.resolve('../');
  final functions = Functions(
    includeSymbolAddress: Declarations.includeSet({'UA_Variant_new'}),
    include: Declarations.includeSet({
      '__UA_Client_AsyncService',
      '__UA_Server_addNode',
      '__UA_Server_write',
      'UA_StatusCode_name',

      'UA_Variant_new',
      'UA_Variant_delete',
      'UA_Variant_copy',

      'UA_ClientConfig_setDefault',
      'UA_Client_delete',
      'UA_Client_disconnect',
      'UA_Client_findDataType',
      'UA_ClientConfig_setDefaultEncryption',
      'UA_CertificateGroup_AcceptAll',
      'UA_ClientConfig_setAuthenticationUsername',
      'UA_Client_newWithConfig',
      'UA_Client_connectAsync',
      'UA_Client_run_iterate',
      'UA_Client_writeValueAttribute_async',
      'UA_Client_getState',
      'UA_ReadRequest_init',
      'UA_ReadRequest_new',
      'UA_ReadRequest_delete',
      'UA_DataValue_new',
      'UA_DataValue_init',
      'UA_DataValue_delete',
      'UA_DataValue_copy',
      'UA_CreateSubscriptionRequest_new',
      'UA_CreateSubscriptionRequest_init',
      'UA_CreateSubscriptionRequest_delete',
      'UA_CreateMonitoredItemsRequest_init',
      'UA_CreateMonitoredItemsRequest_new',
      'UA_CreateMonitoredItemsRequest_delete',
      'UA_Client_Subscriptions_create_async',
      'UA_DeleteMonitoredItemsRequest_new',
      'UA_DeleteMonitoredItemsRequest_init',
      'UA_DeleteMonitoredItemsRequest_delete',
      'UA_Client_cancelByRequestId',
      'UA_Client_MonitoredItems_createDataChanges_async',
      'UA_Client_MonitoredItems_delete_async',
      'UA_Client_call_async',

      'UA_ServerConfig_setMinimal',
      'UA_Server_newWithConfig',
      'UA_Server_getConfig',
      'UA_Server_run_startup',
      'UA_Server_addNode_begin',
      'UA_Server_addNode_finish',
      'UA_Server_setVariableNode_callbackValueSource',
      'UA_Server_addVariableNode',
      'UA_Server_addVariableTypeNode',
      'UA_Server_addNode',
      'UA_Server_writeDescription',
      'UA_Server_readValue',
      'UA_Server_writeValue',
      'UA_Server_findDataType',
      'UA_Server_getLifecycleState',
      'UA_Server_run_iterate',
      'UA_Server_run_shutdown',
      'UA_Server_delete',

      'UA_DataTypeAttributes_new',
      'UA_DataTypeAttributes_delete',

      'UA_VariableTypeAttributes_new',
      'UA_VariableTypeAttributes_delete',
      'UA_VariableAttributes_new',
      'UA_VariableAttributes_delete',

      'UA_LocalizedText_new',
      'UA_LocalizedText_delete',

      'UA_Log_Stdout_new',
      'UA_Log_Stdout_delete',

      'UA_NodeId_new',
      'UA_NodeId_delete',
      'UA_NODEID_STRING',
      'UA_NODEID_NUMERIC',

      'UA_QUALIFIEDNAME',
    }),
    rename: (declaration) {
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
    include: Declarations.includeSet({
      // 'UA_TYPES', The code generated from this variable causes the dart runtime to crash. See : https://github.com/dart-lang/sdk/issues/62087
      'UA_VariableAttributes_default',
    }),
  );

  final macroSet = {
    'UA_OPEN62541_VER_MAJOR',
    'UA_OPEN62541_VER_MINOR',
    'UA_OPEN62541_VER_PATCH',
    'UA_OPEN62541_VER_LABEL',
    'UA_OPEN62541_VER_COMMIT',
    'UA_OPEN62541_VERSION',
    'UA_TYPES_COUNT',
  };

  final macros = Macros(
    include: (decl) {
      if (decl.originalName.startsWith('UA_ACCESSLEVELMASK_') ||
          decl.originalName.startsWith('UA_STATUSCODE_') ||
          decl.originalName.startsWith('UA_TYPES_') ||
          decl.originalName.startsWith('UA_VALUERANK_') ||
          decl.originalName.startsWith('UA_NS0ID_')) {
        return true;
      }
      return macroSet.contains(decl.originalName);
    },
  );

  // Define our generator
  final generator = FfiGenerator(
    headers: Headers(entryPoints: [packageRoot.resolve('third_party/open62541/open62541_modified.h')]),
    functions: functions,
    structs: Structs.includeSet({
      'UA_ClientConfig',
      'UA_Variant',
      'UA_EnumDefinition',
      'UA_EnumField',
      'UA_StructureDefinition',
      'UA_StructureField',
      'UA_ValueSourceNotifications',
      'UA_Server',
      'UA_DataValue',
      'UA_NumericRange',
      'UA_ServerConfig',
      'UA_NodeAttributes',
      'UA_DataTypeAttributes',
      'UA_DataTypeArray',
      'UA_DataTypeMember',
      'UA_WriteResponse',
      'UA_ReadValueId',
      'UA_ReadRequest',
      'UA_ReadResponse',
      'UA_CreateSubscriptionRequest',
      'UA_CreateSubscriptionResponse',
      'UA_DeleteMonitoredItemsResponse',
      'UA_MonitoredItemCreateRequest',
      'UA_MonitoredItemCreateResponse',
      'UA_MonitoredItemCreateResult',
      'UA_CreateMonitoredItemsRequest',
      'UA_CreateMonitoredItemsResponse',
      'UA_CallResponse',
      'UA_CallMethodResult',
      'UA_DeleteMonitoredItemsRequest',
      'UA_DataType',
      'UA_Logger',
    }),
    typedefs: Typedefs.includeSet({
      'UA_Byte',
      'UA_StatusCode',
      'UA_ByteString',
      'UA_Float',
      'UA_Double',
      'UA_Int64',
      'UA_UInt64',
      'UA_Int32',
      'UA_UInt32',
      'UA_Int16',
      'UA_UInt16',
      'UA_SByte',
      'UA_ValueCallback',
    }),
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

''',
    ),
  );
  generator.generate(logger: Logger('')..onRecord.listen((record) => print(record.message)));

  print("Appending workaround for UA_TYPES...");
  var output = File(
    packageRoot.resolve('lib/src/third_party/open62541.g.dart').toFilePath(),
  ).openWrite(mode: FileMode.append);
  output.write('''
// This is mix because the autogenerated version causes the dart runtime to crash
@ffi.Native<UA_DataType>()
external UA_DataType UA_TYPES;
''');
  await output.close();
}
