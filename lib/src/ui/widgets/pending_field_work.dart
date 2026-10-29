import 'dart:async';

import 'package:flutter/widgets.dart';

/// How long a form's Save waits for [PendingFieldWork] before it saves the
/// fields as they stand.
///
/// Six minutes: the SDK's own upload gives up after five
/// (`RestHelper.uploadTimeout`), and the photo field then keeps the photo as
/// a local file that is queued at save, which ends the wait with the photo in
/// the record. The extra minute covers shrinking the photo before the upload
/// and reading the reply after it. So the bound only cuts work that has no
/// limit of its own, such as a host `uploadFile` without a timeout, and does
/// not race a slow upload the SDK would still finish. A shorter bound (the
/// 30-second stall timeouts used for downloads) would save a record without
/// a photo that is still legitimately uploading over a slow link, which is the
/// loss the wait exists to prevent.
const Duration kFieldWorkSaveTimeout = Duration(minutes: 6);

/// Work a field starts on its own and that has to land before the form is
/// submitted, such as a picked photo that is still uploading.
///
/// A form that submits while such work is running reads the field's value from
/// before the work finished, so the save silently drops what the user just did.
/// The form owns one [PendingFieldWork], shares it with its fields through
/// [PendingFieldWorkScope], and waits on [whenIdle] before it reads the values.
class PendingFieldWork {
  final Set<Future<void>> _running = <Future<void>>{};

  /// True while any tracked work has not finished.
  bool get isBusy => _running.isNotEmpty;

  /// Starts watching [work]. A failure is not rethrown here: the field that
  /// started the work already handles it, and the form only needs to know the
  /// work is over.
  void track(Future<void> work) {
    late final Future<void> done;
    done = () async {
      try {
        await work;
      } catch (_) {
        // The field that started the work reports its own failure.
      } finally {
        _running.remove(done);
      }
    }();
    _running.add(done);
  }

  /// Completes once no tracked work is running, including work that was
  /// started while waiting, with true.
  ///
  /// With [timeout], completes with false once [timeout] has passed and work
  /// is still running. The work itself carries on; only the wait ends.
  Future<bool> whenIdle({Duration? timeout}) async {
    Future<void> drain() async {
      while (_running.isNotEmpty) {
        await Future.wait<void>(_running.toList());
      }
    }

    if (timeout == null) {
      await drain();
      return true;
    }
    if (_running.isEmpty) return true;
    try {
      await drain().timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    }
  }
}

/// Tells the Save button of the form below it whether that form is waiting
/// for [PendingFieldWork] before it saves.
///
/// The SDK's own Save buttons (`FormScreen`'s and a child-table row sheet's)
/// sit above the form and only hold its submit callback, so without this the
/// button showed nothing while the form waited and a second tap was silently
/// ignored. A form with no scope above it reports nothing.
class FieldWorkWaitScope extends InheritedWidget {
  const FieldWorkWaitScope({
    super.key,
    required this.waiting,
    required super.child,
  });

  /// Set to true while the form waits, and back to false when it stops.
  final ValueNotifier<bool> waiting;

  /// The nearest scope's notifier, or null when there is none.
  static ValueNotifier<bool>? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<FieldWorkWaitScope>()?.waiting;

  @override
  bool updateShouldNotify(FieldWorkWaitScope oldWidget) =>
      waiting != oldWidget.waiting;
}

/// Hands the nearest form's [PendingFieldWork] to the fields below it.
class PendingFieldWorkScope extends InheritedWidget {
  const PendingFieldWorkScope({
    super.key,
    required this.tracker,
    required super.child,
  });

  final PendingFieldWork tracker;

  /// The enclosing form's tracker, or null when the field is not inside a form
  /// that waits for its fields.
  static PendingFieldWork? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<PendingFieldWorkScope>()?.tracker;

  @override
  bool updateShouldNotify(PendingFieldWorkScope oldWidget) =>
      tracker != oldWidget.tracker;
}
