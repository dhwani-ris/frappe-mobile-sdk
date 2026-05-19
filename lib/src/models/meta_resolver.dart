import 'doc_type_meta.dart';

/// Resolves a [DocTypeMeta] for a given doctype name. The implementation
/// typically goes through a session-scoped cache before falling back to
/// the local `doctype_meta` table or a network fetch.
///
/// Used wherever the SDK needs meta on demand: pull/push engines (P3, P4),
/// the unified read resolver (P5), and the link decorator's target
/// lookup. A single typedef keeps the signature consistent across these
/// surfaces and avoids accidental drift when wiring callbacks.
typedef MetaResolverFn = Future<DocTypeMeta> Function(String doctype);
