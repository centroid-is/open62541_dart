import 'generated/open62541_bindings.dart' as raw;

class AccessLevelMask {
  final bool read;
  final bool write;
  final bool currentRead;
  final bool currentWrite;
  final bool historyRead;
  final bool historyWrite;
  final bool semanticChange;
  final bool statusWrite;
  final bool timestampWrite;

  const AccessLevelMask({
    this.read = false,
    this.write = false,
    this.currentRead = false,
    this.currentWrite = false,
    this.historyRead = false,
    this.historyWrite = false,
    this.semanticChange = false,
    this.statusWrite = false,
    this.timestampWrite = false,
  });

  int get value {
    var ret = read ? raw.UA_ACCESSLEVELMASK_READ : 0;
    ret |= currentRead ? raw.UA_ACCESSLEVELMASK_CURRENTREAD : 0;
    ret |= write ? raw.UA_ACCESSLEVELMASK_WRITE : 0;
    ret |= currentWrite ? raw.UA_ACCESSLEVELMASK_CURRENTWRITE : 0;
    ret |= historyRead ? raw.UA_ACCESSLEVELMASK_HISTORYREAD : 0;
    ret |= historyWrite ? raw.UA_ACCESSLEVELMASK_HISTORYWRITE : 0;
    ret |= semanticChange ? raw.UA_ACCESSLEVELMASK_SEMANTICCHANGE : 0;
    ret |= statusWrite ? raw.UA_ACCESSLEVELMASK_STATUSWRITE : 0;
    ret |= timestampWrite ? raw.UA_ACCESSLEVELMASK_TIMESTAMPWRITE : 0;
    return ret;
  }
}
