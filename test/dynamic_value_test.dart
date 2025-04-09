import 'package:open62541_bindings/dynamic_value.dart';
import 'package:test/test.dart';

void main() {
  test('dynamic value', () {
    final dynamicValue = DynamicValue('test');
    expect(dynamicValue.type, DynamicType.nullValue);
  });

  test('add field', () {
    final dynamicValue = DynamicValue('test');
    dynamicValue['field1'] = DynamicValue('field1');
    expect(dynamicValue.type, DynamicType.object);
  });

  test('add index', () {
    final dynamicValue = DynamicValue('test');
    dynamicValue[0] = DynamicValue('field1');
    expect(dynamicValue.type, DynamicType.array);
  });

  test('add index out of bounds', () {
    final dynamicValue = DynamicValue('test');
    expect(() => dynamicValue[1] = DynamicValue('field1'), throwsStateError);
  });

  test('set value', () {
    final dynamicValue = DynamicValue('test');
    dynamicValue.value = 42.2;
    expect(dynamicValue.type, DynamicType.float);
  });
}
