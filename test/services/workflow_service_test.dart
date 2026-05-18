import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/services/workflow_service.dart';

/// Records every request and returns scripted responses keyed by method name.
class _ScriptedHttp {
  _ScriptedHttp(this.responses);
  final Map<String, http.Response> responses;
  final List<Map<String, dynamic>> sent = [];

  http.Client build() => MockClient((req) async {
    sent.add({
      'method': req.method,
      'url': req.url.toString(),
      'body': req.body.isEmpty ? null : jsonDecode(req.body),
    });
    // Frappe URLs end with /api/method/<dotted.method.name>. Match on
    // the short method suffix the test cares about (e.g. `get_transitions`).
    final last = req.url.pathSegments.last;
    for (final entry in responses.entries) {
      if (last == entry.key || last.endsWith('.${entry.key}')) {
        return entry.value;
      }
    }
    return http.Response(jsonEncode({'message': null}), 200);
  });
}

http.Response _ok(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: const {'content-type': 'application/json'},
);

void main() {
  group('getTransitions', () {
    test('returns parsed transitions from {"message": [...]}', () async {
      final http = _ScriptedHttp({
        'get_transitions': _ok({
          'message': [
            {
              'action': 'Approve',
              'next_state': 'Approved',
              'state': 'Pending',
              'allowed': 'Manager',
              'allow_self_approval': 1,
            },
            {'action': 'Reject', 'next_state': 'Rejected', 'state': 'Pending'},
          ],
        }),
      });
      final client = FrappeClient('http://localhost', httpClient: http.build());
      final svc = WorkflowService(client);

      final out = await svc.getTransitions('Leave Application', 'LA-001');
      expect(out, hasLength(2));
      expect(out[0].action, 'Approve');
      expect(out[0].nextState, 'Approved');
      expect(out[0].state, 'Pending');
      expect(out[0].allowed, 'Manager');
      expect(out[0].allowSelfApproval, isTrue);
      expect(out[1].action, 'Reject');
      expect(
        out[1].allowSelfApproval,
        isFalse,
        reason: 'missing allow_self_approval defaults to false',
      );
    });

    test('sends the correct payload (doctype + docname)', () async {
      final http = _ScriptedHttp({
        'get_transitions': _ok({'message': []}),
      });
      final client = FrappeClient('http://localhost', httpClient: http.build());
      final svc = WorkflowService(client);

      await svc.getTransitions('Leave Application', 'LA-001');
      expect(http.sent, hasLength(1));
      expect(http.sent.first['method'], 'POST');
      expect(http.sent.first['url'], contains('get_transitions'));
      expect(http.sent.first['body'], {
        'doc': {'doctype': 'Leave Application', 'name': 'LA-001'},
      });
    });

    test('returns empty list when server returns bare null', () async {
      final http = _ScriptedHttp({
        'get_transitions': _ok({'message': null}),
      });
      final client = FrappeClient('http://localhost', httpClient: http.build());
      final svc = WorkflowService(client);

      final out = await svc.getTransitions('Leave Application', 'LA-001');
      expect(out, isEmpty);
    });

    test('unwraps {"docs": [...]} envelope when present', () async {
      final http = _ScriptedHttp({
        'get_transitions': _ok({
          'docs': [
            {'action': 'Approve', 'next_state': 'Approved', 'state': 'Pending'},
          ],
        }),
      });
      final client = FrappeClient('http://localhost', httpClient: http.build());
      final svc = WorkflowService(client);

      final out = await svc.getTransitions('Leave Application', 'LA-001');
      expect(out.single.action, 'Approve');
    });

    test('returns empty list when message is not a list', () async {
      final http = _ScriptedHttp({
        'get_transitions': _ok({'message': 'oops'}),
      });
      final client = FrappeClient('http://localhost', httpClient: http.build());
      final svc = WorkflowService(client);

      final out = await svc.getTransitions('Leave Application', 'LA-001');
      expect(out, isEmpty);
    });

    test('skips entries that are not maps', () async {
      final http = _ScriptedHttp({
        'get_transitions': _ok({
          'message': [
            'not-a-map',
            {'action': 'Approve', 'next_state': 'Approved', 'state': 'Pending'},
            42,
          ],
        }),
      });
      final client = FrappeClient('http://localhost', httpClient: http.build());
      final svc = WorkflowService(client);

      final out = await svc.getTransitions('Leave Application', 'LA-001');
      expect(out, hasLength(1));
      expect(out.single.action, 'Approve');
    });

    test('handles allow_self_approval as bool true', () async {
      final http = _ScriptedHttp({
        'get_transitions': _ok({
          'message': [
            {
              'action': 'Approve',
              'next_state': 'Approved',
              'state': 'Pending',
              'allow_self_approval': true,
            },
          ],
        }),
      });
      final client = FrappeClient('http://localhost', httpClient: http.build());
      final svc = WorkflowService(client);

      final out = await svc.getTransitions('Leave Application', 'LA-001');
      expect(out.single.allowSelfApproval, isTrue);
    });
  });

  group('applyWorkflow', () {
    test('returns the updated document map on success', () async {
      final http = _ScriptedHttp({
        'apply_workflow': _ok({
          'name': 'LA-001',
          'workflow_state': 'Approved',
          'docstatus': 1,
        }),
      });
      final client = FrappeClient('http://localhost', httpClient: http.build());
      final svc = WorkflowService(client);

      final out = await svc.applyWorkflow(
        'Leave Application',
        'LA-001',
        'Approve',
      );
      expect(out['workflow_state'], 'Approved');
      expect(out['name'], 'LA-001');
    });

    test('sends doctype + name + action', () async {
      final http = _ScriptedHttp({
        'apply_workflow': _ok({'name': 'LA-001'}),
      });
      final client = FrappeClient('http://localhost', httpClient: http.build());
      final svc = WorkflowService(client);

      await svc.applyWorkflow('Leave Application', 'LA-001', 'Reject');
      expect(http.sent.single['body'], {
        'doc': {'doctype': 'Leave Application', 'name': 'LA-001'},
        'action': 'Reject',
      });
    });

    test(
      'returns server map even when shape is unexpected (no normalization)',
      () async {
        final http = _ScriptedHttp({
          'apply_workflow': _ok({
            'message': ['unexpected', 'list'],
          }),
        });
        final client = FrappeClient(
          'http://localhost',
          httpClient: http.build(),
        );
        final svc = WorkflowService(client);

        // Implementation contract: any Map<String, dynamic> is returned as-is.
        // The {name: docname} fallback only kicks in for non-map responses.
        final out = await svc.applyWorkflow(
          'Leave Application',
          'LA-001',
          'Approve',
        );
        expect(out, isA<Map<String, dynamic>>());
        expect(out['message'], ['unexpected', 'list']);
      },
    );
  });
}
