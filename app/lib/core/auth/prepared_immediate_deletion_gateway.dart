import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../privacy/cloud_egress_gate.dart';
import '../session/account_scope.dart';
import '../session/admission_authority.dart';
import '../session/app_session.dart';
import 'immediate_account_deletion.dart';
import 'immediate_deletion_receipt_store.dart';

/// INACTIVE source preparation. This is deliberately not AccountDeletionGateway.
/// No provider/UI registration, local finalization, sign-out or polling belongs
/// here. SDK wiring is trusted: the public host proof cannot expose its private
/// issuer client for an independent object-identity check. Activation must qualify
/// that wiring separately. Custody remains foreground-isolate scoped, not CAS.
final class PreparedImmediateDeletionGateway {
  PreparedImmediateDeletionGateway({
    required AppSession session,
    required AccountScopeHost host,
    required SupabaseClient client,
    required ImmediateDeletionReceiptStore store,
    required http.Client transport,
    required Uri functionUrl,
    CloudEgressGate? gate,
    Duration requestTimeout = kAccountControlTtl,
    String? apiKey,
  })  : _session = session,
        _host = host,
        _client = client,
        _store = store,
        _transport = transport,
        _functionUrl = functionUrl,
        _gate = gate ?? CloudEgressGate.instance,
        _requestTimeout = requestTimeout,
        _apiKey = apiKey;

  final AppSession _session;
  final AccountScopeHost _host;
  final SupabaseClient _client;
  final ImmediateDeletionReceiptStore _store;
  final http.Client _transport;
  final Uri _functionUrl;
  final CloudEgressGate _gate;
  final Duration _requestTimeout;
  final String? _apiKey;
  final Set<Future<void>> _pending = {};
  final List<(Object, StackTrace)> _unexpected = [];

  /// Capture happens before any await. Missing authority is never recaptured.
  Future<PreparedDeletionOperation?> prepare({bool Function()? restrict}) =>
      _prepare(resume: false, restrict: restrict);

  /// Explicitly selects the captured admitted owner's existing pending custody.
  /// Signed-out recovery remains the existing Recovery.restore API, unchanged.
  Future<PreparedDeletionOperation?> resumePending(
          {bool Function()? restrict}) =>
      _prepare(resume: true, restrict: restrict);

  Future<PreparedDeletionOperation?> _prepare({
    required bool resume,
    bool Function()? restrict,
  }) {
    final original = _capture(restrict);
    return _own(() async {
      if (original == null) {
        return null;
      }
      try {
        final record = await _store.serialized(() async {
          if (!original.current) {
            throw const _BindingLost();
          }
          return _store.load(original.binding.owner!);
        });
        if (!original.current ||
            record?.phase == ImmediateDeletionPhase.completed ||
            (resume ? record == null : record != null)) {
          return null;
        }
        final operation = PreparedDeletionOperation._(
          this,
          original,
          record?.operationId ?? generateReceiptSecret(),
          record?.receiptSecret,
          resume,
        );
        final observed = _OperationReceiptStore(_store, operation);
        operation._observed = observed;
        operation._recovery = ImmediateAccountDeletionRecovery(
          store: observed,
          transport: _transport,
          functionUrl: _functionUrl,
          gate: _gate,
          requestTimeout: _requestTimeout,
          apiKey: _apiKey,
          captureBinding: () async => original.binding,
          isBindingCurrent: (binding) =>
              identical(binding, original.binding) && original.current,
          newOperationId: () => operation._operationId,
          newReceipt: () => operation._secret ??= generateReceiptSecret(),
        );
        return original.current ? operation : null;
      } catch (_) {
        return null;
      }
    });
  }

  _OriginalBinding? _capture(bool Function()? restrict) {
    try {
      final admission = _session.captureDatabaseHostAdmission();
      final origin = _session.captureCallbackOrigin();
      final scope = _host.current;
      final sdk = _client.auth.currentSession;
      if (admission == null ||
          origin == null ||
          scope == null ||
          sdk == null ||
          scope.isLocalRead ||
          scope.uid != admission.uid ||
          origin.uid != admission.uid ||
          sdk.user.id != admission.uid ||
          sdk.isExpired ||
          sdk.accessToken.isEmpty ||
          !identical(scope.database, admission.database) ||
          scope.generation != admission.scopeGeneration) {
        return null;
      }
      final original = _OriginalBinding(
        admission,
        origin,
        _host,
        scope,
        _client,
        _gate,
        _gate.epoch,
        ImmediateDeletionBinding(
            owner: admission.uid,
            lifecycle: origin.epoch,
            bearerToken: sdk.accessToken),
        restrict,
      );
      return original.current ? original : null;
    } catch (_) {
      return null;
    }
  }

  /// Challenge/recent-auth acquisition is an external prerequisite, not proof
  /// manufactured by this adapter. Only this handle's first request can use it.
  Future<PreparedDeletionOutcome> request(
    PreparedDeletionOperation operation, {
    required String challengeId,
    required String challengeResponse,
  }) =>
      _enqueue(operation, () async {
        if (operation._attempted || operation._resumed) {
          return const PreparedDeletionUnconfirmed._(
              PreparedDeletionUnconfirmedReason.operationClosed);
        }
        operation._attempted = true;
        return _exchange(
            operation,
            () => operation._recovery.request(
                challengeId: challengeId,
                challengeResponse: challengeResponse));
      });

  /// No challenge, new operation or authorization POST is created by recovery.
  Future<PreparedDeletionOutcome> recover(
          PreparedDeletionOperation operation) =>
      _enqueue(operation, () async {
        if (!operation._attempted && !operation._resumed) {
          return const PreparedDeletionUnconfirmed._(
              PreparedDeletionUnconfirmedReason.operationClosed);
        }
        return _exchange(operation, () async {
          final handle = await operation._recovery
              .restore(owner: operation._original.binding.owner!);
          if (handle == null) {
            return const ImmediateDeletionFailed('',
                retryable: false, code: 'operation_closed');
          }
          return operation._recovery.recover(handle);
        });
      });

  Future<PreparedDeletionOutcome> _enqueue(PreparedDeletionOperation operation,
      Future<PreparedDeletionOutcome> Function() action) {
    if (!identical(operation._issuer, this)) {
      return Future.value(const PreparedDeletionUnconfirmed._(
          PreparedDeletionUnconfirmedReason.foreignOperation));
    }
    // Own queued work before invoking it. Never place network in session drains.
    final prior = operation._tail;
    final result = _own(() async {
      await prior;
      if (operation._closed) {
        return const PreparedDeletionUnconfirmed._(
            PreparedDeletionUnconfirmedReason.operationClosed);
      }
      if (!operation._original.current) {
        return const PreparedDeletionUnconfirmed._(
            PreparedDeletionUnconfirmedReason.staleContext);
      }
      return action();
    });
    operation._tail =
        result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<PreparedDeletionOutcome> _exchange(PreparedDeletionOperation operation,
      Future<ImmediateDeletionResult> Function() invoke) async {
    final observation = _ExchangeObservation();
    operation._observed._active = observation;
    try {
      // Recovery owns the shared store lock. An outer serialized call self-waits.
      final result = await invoke();
      if (!operation._original.current) {
        observation.lost = true;
      }
      if (operation._closed) {
        return const PreparedDeletionUnconfirmed._(
            PreparedDeletionUnconfirmedReason.operationClosed);
      }
      if (observation.mismatch) {
        return const PreparedDeletionUnconfirmed._(
            PreparedDeletionUnconfirmedReason.receiptChanged);
      }
      if (observation.lost) {
        return const PreparedDeletionUnconfirmed._(
            PreparedDeletionUnconfirmedReason.staleContext);
      }
      if (result is ImmediateDeletionCompleted &&
          observation.completedVerified &&
          operation._secret != null &&
          result.receiptSecret.isNotEmpty &&
          result.receiptSecret == operation._secret) {
        operation._closed = true;
        return PreparedDeletionRemoteCompletion._(operation);
      }
      if (result is ImmediateDeletionAccepted) {
        return const PreparedDeletionPending._(
            PreparedDeletionPendingKind.accepted);
      }
      if (result is ImmediateDeletionInProgress) {
        return const PreparedDeletionPending._(
            PreparedDeletionPendingKind.inProgress);
      }
      return PreparedDeletionUnconfirmed._(result is ImmediateDeletionFailed &&
              result.code == 'receipt_store_unavailable'
          ? PreparedDeletionUnconfirmedReason.receiptStoreUnavailable
          : PreparedDeletionUnconfirmedReason.protocolUnconfirmed);
    } finally {
      operation._observed._active = null;
    }
  }

  /// Close delivery, not server execution or custody of an already-started call.
  void close(PreparedDeletionOperation operation) {
    if (!identical(operation._issuer, this)) {
      return;
    }
    operation._closed = true;
  }

  Future<T> _own<T>(Future<T> Function() start) {
    final terminal = Completer<void>();
    _pending.add(terminal.future);
    late Future<T> result;
    try {
      result = start();
    } catch (error, stack) {
      result = Future<T>.error(error, stack);
    }
    unawaited(result.then<void>((_) {
      _pending.remove(terminal.future);
      terminal.complete();
    }, onError: (Object error, StackTrace stack) {
      _unexpected.add((error, stack));
      _pending.remove(terminal.future);
      terminal.complete();
    }));
    return result;
  }

  /// Observes actual queued/running settlement. It sends and cancels nothing.
  Future<void> waitPendingWork() async {
    while (_pending.isNotEmpty) {
      await Future.wait(_pending.toList());
    }
    if (_unexpected.isNotEmpty) {
      Error.throwWithStackTrace(_unexpected.first.$1, _unexpected.first.$2);
    }
  }
}

final class PreparedDeletionOperation {
  PreparedDeletionOperation._(this._issuer, this._original, this._operationId,
      this._secret, this._resumed);
  final PreparedImmediateDeletionGateway _issuer;
  final _OriginalBinding _original;
  final String _operationId;
  String? _secret;
  final bool _resumed;
  bool _attempted = false;
  bool _closed = false;
  Future<void> _tail = Future<void>.value();
  late _OperationReceiptStore _observed;
  late ImmediateAccountDeletionRecovery _recovery;
  @override
  String toString() => 'PreparedDeletionOperation';
}

sealed class PreparedDeletionOutcome {
  const PreparedDeletionOutcome._();
}

enum PreparedDeletionPendingKind { accepted, inProgress }

final class PreparedDeletionPending extends PreparedDeletionOutcome {
  const PreparedDeletionPending._(this.kind) : super._();
  final PreparedDeletionPendingKind kind;
}

enum PreparedDeletionUnconfirmedReason {
  staleContext,
  foreignOperation,
  operationClosed,
  receiptChanged,
  receiptStoreUnavailable,
  protocolUnconfirmed,
}

final class PreparedDeletionUnconfirmed extends PreparedDeletionOutcome {
  const PreparedDeletionUnconfirmed._(this.reason) : super._();
  final PreparedDeletionUnconfirmedReason reason;
}

/// Remote protocol evidence for the original operation ONLY. This grants no
/// local erasure, auth mutation, navigation or user-visible deletion success.
final class PreparedDeletionRemoteCompletion extends PreparedDeletionOutcome {
  const PreparedDeletionRemoteCompletion._(this.operation) : super._();
  final PreparedDeletionOperation operation;
}

final class _OriginalBinding {
  _OriginalBinding(this.admission, this.origin, this.host, this.scope,
      this.client, this.gate, this.egressEpoch, this.binding, this.restrict);
  final DatabaseHostAdmission admission;
  final AdmissionAuthority origin;
  final AccountScopeHost host;
  final AccountScope scope;
  final SupabaseClient client;
  final CloudEgressGate gate;
  final int egressEpoch;
  final ImmediateDeletionBinding binding;
  final bool Function()? restrict;
  bool _lost = false;
  bool get current {
    if (_lost) {
      return false;
    }
    try {
      final sdk = client.auth.currentSession;
      if (!admission.isCurrent ||
          !origin.isCurrent ||
          !identical(host.current, scope) ||
          !identical(scope.database, admission.database) ||
          scope.generation != admission.scopeGeneration ||
          scope.isLocalRead ||
          !scope.database.admitsSecondary ||
          sdk == null ||
          sdk.isExpired ||
          sdk.user.id != binding.owner ||
          sdk.accessToken != binding.bearerToken ||
          !identical(gate, CloudEgressGate.instance) ||
          gate.epoch != egressEpoch ||
          !(restrict?.call() ?? true)) {
        _lost = true;
      }
    } catch (_) {
      _lost = true;
    }
    return !_lost;
  }
}

final class _BindingLost implements Exception {
  const _BindingLost();
}

final class _ExchangeObservation {
  bool mismatch = false;
  bool lost = false;
  bool completedVerified = false;
}

/// Transparent, restrictive observer of the unchanged recovery's own lock and
/// verified persistence. No positive completion witness is derived from loads.
final class _OperationReceiptStore extends ImmediateDeletionReceiptStore {
  _OperationReceiptStore(this.base, this.operation)
      : super(authority: base.authority);
  final ImmediateDeletionReceiptStore base;
  final PreparedDeletionOperation operation;
  _ExchangeObservation? _active;
  @override
  Future<T> serialized<T>(Future<T> Function() body) => base.serialized(body);

  Never _mismatch() {
    _active?.mismatch =
        true; // Irrevocable, even if recovery catches sanitation.
    throw const ImmediateDeletionReceiptStoreException();
  }

  void _current() {
    if (!operation._original.current) {
      _active?.lost = true;
      throw const _BindingLost();
    }
  }

  bool _matches(ImmediateDeletionReceipt record) =>
      record.owner == operation._original.binding.owner &&
      record.operationId == operation._operationId &&
      record.receiptSecret == operation._secret;

  @override
  Future<ImmediateDeletionReceipt?> load(String owner) async {
    _current();
    if (owner != operation._original.binding.owner) {
      _mismatch();
    }
    final record = await base.load(owner);
    _current();
    if (record == null) {
      if (operation._resumed || operation._secret != null) {
        _mismatch();
      }
    } else if (!_matches(record) ||
        record.phase == ImmediateDeletionPhase.completed) {
      _mismatch();
    }
    return record;
  }

  @override
  Future<void> writeVerified(ImmediateDeletionReceipt receipt) async {
    _current();
    if (receipt.owner != operation._original.binding.owner ||
        receipt.operationId != operation._operationId ||
        (receipt.receiptSecret != operation._secret &&
            !(receipt.phase == ImmediateDeletionPhase.completed &&
                receipt.receiptSecret == null))) {
      _mismatch();
    }
    final ImmediateDeletionReceipt? previous;
    try {
      previous = await base.load(receipt.owner);
    } catch (_) {
      // Sanitization is best effort in recovery, but an unreadable predecessor
      // cannot preserve this invocation's positive completion observation.
      _active?.mismatch = true;
      rethrow;
    }
    _current();
    final valid = switch (receipt.phase) {
      ImmediateDeletionPhase.created =>
        previous == null && receipt.receiptSecret != null,
      ImmediateDeletionPhase.mayHaveBeenSent => previous != null &&
          _matches(previous) &&
          previous.phase == ImmediateDeletionPhase.created,
      ImmediateDeletionPhase.completed => previous != null &&
          (receipt.receiptSecret == null
              ? previous.operationId == operation._operationId &&
                  previous.owner == receipt.owner &&
                  previous.receiptSecret == operation._secret &&
                  previous.phase == ImmediateDeletionPhase.completed &&
                  (_active?.completedVerified ?? false)
              : _matches(previous) &&
                  previous.phase != ImmediateDeletionPhase.completed),
    };
    if (!valid) {
      _mismatch();
    }
    try {
      await base.writeVerified(receipt);
    } catch (_) {
      // Recovery deliberately swallows best-effort sanitization errors. A
      // changed/unreadable record must still poison this invocation forever.
      if (receipt.phase == ImmediateDeletionPhase.completed &&
          receipt.receiptSecret == null) {
        try {
          final retained = await base.load(receipt.owner);
          if (retained == null ||
              retained.owner != receipt.owner ||
              retained.operationId != operation._operationId ||
              retained.phase != ImmediateDeletionPhase.completed ||
              (retained.receiptSecret != null &&
                  retained.receiptSecret != operation._secret)) {
            _mismatch();
          }
        } catch (_) {
          _active?.mismatch = true;
        }
      }
      rethrow;
    }
    _current();
    if (receipt.phase == ImmediateDeletionPhase.completed &&
        receipt.receiptSecret != null) {
      _active?.completedVerified = true;
    }
  }
}
