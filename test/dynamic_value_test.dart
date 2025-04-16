import 'dart:collection';

import 'package:open62541_bindings/src/dynamic_value.dart';
import 'package:open62541_bindings/src/extensions.dart';
import 'package:test/test.dart';
import 'package:open62541_bindings/src/nodeId.dart';

void main() {
  test('dynamic value', () {
    final dynamicValue = DynamicValue();
    expect(dynamicValue.type, DynamicType.nullValue);
  });

  test('add field', () {
    final dynamicValue = DynamicValue();
    dynamicValue['field1'] = DynamicValue();
    expect(dynamicValue.type, DynamicType.object);
  });

  test('add index', () {
    final dynamicValue = DynamicValue();
    dynamicValue[0] = DynamicValue();
    expect(dynamicValue.type, DynamicType.array);
  });

  test('add index out of bounds', () {
    final dynamicValue = DynamicValue();
    expect(() => dynamicValue[1] = DynamicValue(), throwsStateError);
  });

  test('set value', () {
    final dynamicValue = DynamicValue();
    dynamicValue.value = 42.2;
    expect(dynamicValue.type, DynamicType.float);
  });
  test('set sub values', () {
    var values = <String, dynamic>{
      "jbb": false,
      "ohg": true,
      "w": {
        "jbb": true,
        "w": {
          "ohg": false,
          "a": [
            {
              "jbb": false,
              "ohg": [
                {"final_boss": true},
                [
                  [1337]
                ]
              ]
            }
          ]
        }
      }
    };
    final d = DynamicValue.fromMap(values);
    expect(d["ohg"].asBool, true);
    expect(d["jbb"].asBool, false);
    expect(d["w"]["jbb"].asBool, true);
    expect(d["w"]["w"]["ohg"].asBool, false);
    expect(d["w"]["w"]["a"][0]["jbb"].asBool, false);
    expect(d["w"]["w"]["a"][0]["ohg"][0]["final_boss"].asBool, true);
    expect(d["w"]["w"]["a"][0]["ohg"][1][0][0].asInt, 1337);
    d["jbb"] = true;
    d["w"]["jbb"] = false;
    d["w"]["w"]["ohg"] = true;
    d["w"]["w"]["a"][0]["jbb"] = true;
    d["w"]["w"]["a"][0]["ohg"][0]["final_boss"] = false;
    d["w"]["w"]["a"][0]["ohg"][1][0][0] = 42;
    expect(d["jbb"].asBool, true);
    expect(d["w"]["jbb"].asBool, false);
    expect(d["w"]["w"]["ohg"].asBool, true);
    expect(d["w"]["w"]["a"][0]["jbb"].asBool, true);
    expect(d["w"]["w"]["a"][0]["ohg"][0]["final_boss"].asBool, false);
    expect(d["w"]["w"]["a"][0]["ohg"][1][0][0].asInt, 42);
  });
  test('typeId persistance trivial', () {
    DynamicValue k = DynamicValue(value: false, typeId: NodeId.boolean);
    expect(k.typeId, NodeId.boolean);
    k.value = true;
    expect(k.typeId, NodeId.boolean);
  });
  test('typeId persistance complex map', () {
    var values = <String, dynamic>{
      "jbb": false,
    };
    final d = DynamicValue.fromMap(values);
    d["jbb"].typeId = NodeId.boolean;
    expect(d["jbb"].typeId, NodeId.boolean);
    d["jbb"] = true;
    expect(d["jbb"].typeId, NodeId.boolean);
  });
  test('typeId persistance array', () {
    var values = [
      DynamicValue(value: true, typeId: NodeId.boolean),
      DynamicValue(value: false, typeId: NodeId.boolean),
    ];
    final d = DynamicValue.fromList(values);
    expect(d[0].typeId, NodeId.boolean);
    expect(d[1].typeId, NodeId.boolean);
    d[0] = false;
    d[1] = true;
    expect(d[0].typeId, NodeId.boolean);
    expect(d[1].typeId, NodeId.boolean);
  });
}
