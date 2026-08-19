/// A snapshot of on-device attachment media usage.
///
/// [orphanBytes] is a SUBSET of [outboxBytes] — reclaimable staged files are
/// still staged files. It is deliberately excluded from [totalBytes] so a
/// caller cannot double-count them.
class MediaStoreUsage {
  /// Staged, not yet uploaded. Correctness storage: the only copy.
  final int outboxBytes;

  /// Uploaded or downloaded content. A performance copy; always re-fetchable.
  final int cacheBytes;

  /// How much of [outboxBytes] a sweep would reclaim right now.
  final int orphanBytes;

  /// How many files that is.
  final int orphanCount;

  const MediaStoreUsage({
    required this.outboxBytes,
    required this.cacheBytes,
    required this.orphanBytes,
    required this.orphanCount,
  });

  int get totalBytes => outboxBytes + cacheBytes;

  @override
  String toString() =>
      'MediaStoreUsage(outbox: $outboxBytes, cache: $cacheBytes, '
      'orphan: $orphanBytes in $orphanCount files)';
}
