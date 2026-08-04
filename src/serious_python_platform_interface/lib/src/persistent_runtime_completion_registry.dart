import 'dart:async';

/// Tracks completion futures for one persistent Python runtime epoch.
///
/// A Dart VM can be recreated while the embedded Python interpreter remains
/// alive. Command IDs start from one in each VM, so an ID alone is not a safe
/// completion key. The epoch is carried on both commands and replies and is
/// checked before a completion is resolved.
class PersistentRuntimeCompletionRegistry {
  PersistentRuntimeCompletionRegistry(this.epoch) {
    if (epoch.isEmpty) {
      throw ArgumentError.value(epoch, 'epoch', 'must not be empty');
    }
  }

  final String epoch;
  final Map<_PersistentRuntimeCompletionKey, Completer<int>> _completions = {};

  void register(int commandId, Completer<int> completer) {
    final key = _PersistentRuntimeCompletionKey(epoch, commandId);
    if (_completions.containsKey(key)) {
      throw StateError('Duplicate persistent runtime command $commandId');
    }
    _completions[key] = completer;
  }

  bool remove(int commandId) =>
      _completions.remove(_PersistentRuntimeCompletionKey(epoch, commandId)) !=
      null;

  /// Applies a native completion if it belongs to this runtime epoch.
  ///
  /// Returns false for malformed, stale, duplicate, or otherwise unrelated
  /// replies. Such replies are expected during a Dart VM restart and must not
  /// affect the new VM's command futures.
  bool complete(Map<String, dynamic> response) {
    final responseEpoch = response['runtimeEpoch'];
    final commandId = response['id'];
    final result = response['rc'];
    if (responseEpoch != epoch || commandId is! int || result is! int) {
      return false;
    }

    final completer =
        _completions.remove(_PersistentRuntimeCompletionKey(epoch, commandId));
    if (completer == null || completer.isCompleted) return false;
    completer.complete(result);
    return true;
  }
}

final class _PersistentRuntimeCompletionKey {
  const _PersistentRuntimeCompletionKey(this.epoch, this.commandId);

  final String epoch;
  final int commandId;

  @override
  bool operator ==(Object other) =>
      other is _PersistentRuntimeCompletionKey &&
      other.epoch == epoch &&
      other.commandId == commandId;

  @override
  int get hashCode => Object.hash(epoch, commandId);
}
