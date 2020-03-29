import 'dart:async';
import 'dart:convert' show utf8;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_firestore_mocks/cloud_firestore_mocks.dart';
import 'package:flutter/services.dart';
import 'package:flutter_driver/driver_extension.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:test/test.dart' as _test;

import 'firestore_clients.dart';

/// Test cases to compare 3 Firestore implementation behaviors: Cloud
/// Firestore backend, Emulator backend, and cloud_firestore_mocks.
void main() {
  final Completer<String> completer = Completer<String>();
  enableFlutterDriverExtension(handler: (_) => completer.future);
  tearDownAll(() => completer.complete(null));

  // cloud_firestore backed by Cloud Firestore (project ID: flutter-firestore)
  firestoreFutures = {
    'Cloud Firestore': createFireStoreClient('test', null, true),

    // cloud_firestore backed by Firestore Emulator
    'Firestore Emulator':
        createFireStoreClient('test2', 'localhost:8080', false),

    // cloud_firestore_mocks
    'cloud_firestore_mocks': Future.value(MockFirestoreInstance())
  };

  group('Firestore behavior comparison:', () {
    ftest('Document creation by add', (firestore) async {
      final CollectionReference messages = firestore.collection('messages');

      final doc = await messages.add({
        'message': 'hello firestore',
        'created_at': DateTime
            .now(), // MockFieldValue interferes FieldValue.serverTimestamp
      });
      final String documentId = doc.documentID;
      final result = await doc.get();

      await doc.delete();

      expect(documentId.length, _test.greaterThanOrEqualTo(20));
      expect(result.data['message'], 'hello firestore');
    });

    ftest('Document creation by setData', (firestore) async {
      final CollectionReference messages = firestore.collection('messages');

      final DocumentReference doc = messages.document();
      final String documentId = doc.documentID;

      final currentDateTime = DateTime.now();
      await doc.setData(<String, dynamic>{
        'message': 'hello firestore',
        'created_at': currentDateTime,
        'nested1': {
          'field2': 2,
          'nested2': {
            'field3': 3,
            'nested3': {'field4': 4}
          }
        }
      });

      final result = await doc.get();

      await doc.delete();

      expect(result.documentID, documentId);
      expect(result.data['message'], 'hello firestore');
      final map1 = result.data['nested1'] as Map<String, dynamic>;
      expect(map1['field2'], 2);
      final map2 = map1['nested2'] as Map<String, dynamic>;
      expect(map2['field3'], 3);
      final map3 = map2['nested3'] as Map<String, dynamic>;
      expect(map3['field4'], 4);
    });

    ftest('Timestamp field', (firestore) async {
      final CollectionReference messages = firestore.collection('messages');
      final DocumentReference doc = messages.document();

      final currentDateTime = DateTime.now();
      await doc.setData(<String, dynamic>{
        'message': 'hello firestore',
        'created_at': currentDateTime,
      });

      final result = await doc.get();

      await doc.delete();

      expect(result.data['created_at'], _test.isA<Timestamp>());
      final createdAt = (result.data['created_at'] as Timestamp).toDate();

      // The conversion between Dart's DateTime and Firestore's Timestamp is not a
      // loss-less conversion. For example, asserting createdAt equals to currentDateTime
      // would fail:
      //   Expected: DateTime:<2020-03-10 19:45:26.610680>
      //   Actual: DateTime:<2020-03-10 19:45:26.609999>
      final timeDiff = createdAt.difference(currentDateTime);
      // The difference should be 1 millisecond.
      expect(timeDiff.inMilliseconds, _test.lessThanOrEqualTo(1));
    });

    ftest('Unsaved documens', (firestore) async {
      final CollectionReference recipients = firestore.collection('messages');

      final DocumentReference doc = recipients.document();
      final String documentId = doc.documentID;

      final result = await doc.get();

      expect(documentId.length, _test.greaterThanOrEqualTo(20));
      expect(doc.path, 'messages/$documentId');
      expect(result.data, null);
    });

    ftest('Nested objects creation with updateData', (firestore) async {
      final CollectionReference messages = firestore.collection('messages');

      final DocumentReference doc = messages.document();
      // updateData requires an existing document
      await doc.setData({'foo': 'bar'});

      await doc.updateData({
        'nested.data.message': 'value in nested data',
      });

      final result = await doc.get();

      await doc.delete();

      final nested = result.data['nested'] as Map<String, dynamic>;
      final nestedData = nested['data'] as Map<String, dynamic>;
      expect(nestedData['message'], 'value in nested data');
    });

    ftest('Nested objects update', (firestore) async {
      final CollectionReference messages = firestore.collection('messages');

      final DocumentReference doc = messages.document();
      // updateData requires an existing document
      await doc.setData({
        'foo': 'bar',
        'nested': {
          'data': {'message': 'old value1', 'unaffected_field': 'old value2'}
        }
      });

      await doc.updateData({
        'nested.data.message': 'updated value',
      });
      final result2 = await doc.get();

      await doc.delete();

      final nested2 = result2.data['nested'] as Map<dynamic, dynamic>;
      final nestedData2 = nested2['data'] as Map<dynamic, dynamic>;
      expect(nestedData2['message'], 'updated value');
      expect(nestedData2['unaffected_field'], 'old value2');
    });

    ftest('Snapshot should not be affected by updates', (firestore) async {
      final CollectionReference messages = firestore.collection('messages');

      final DocumentReference doc = messages.document();
      // updateData requires an existing document
      await doc.setData({
        'foo': 'old',
        'nested': {
          'data': {'message': 'old nested data'}
        }
      });

      final snapshot = await doc.get();

      await doc.setData({'foo': 'new'});
      await doc.updateData({'nested.data.message': 'new nested data'});

      await doc.delete();

      // At the time the snapshot was created, the value was 'old'
      expect(snapshot.data['foo'], 'old');
      final nested = snapshot.data['nested'] as Map<String, dynamic>;
      final nestedData = nested['data'] as Map<String, dynamic>;
      expect(nestedData['message'], 'old nested data');
    });

    ftest('Transaction: get, set, update, and delete', (firestore) async {
      final foo = firestore.collection('messages').document('foo');
      final bar = firestore.collection('messages').document('bar');
      final baz = firestore.collection('messages').document('baz');
      await foo.setData({'name': 'Foo'});
      await bar.setData({'name': 'Bar'});
      await baz.setData({'name': 'Baz'});

      final result = await firestore.runTransaction((tx) async {
        final snapshotFoo = await tx.get(foo);

        await tx.set(foo, {
          'name': snapshotFoo.data['name'] + 'o',
        });
        await tx.update(bar, {
          'nested.field': 123,
        });
        await tx.delete(baz);
        return {'k': 'v'};
      });
      expect(result['k'], 'v');

      final updatedSnapshotFoo = await foo.get();
      expect(updatedSnapshotFoo.data['name'], 'Fooo');

      final updatedSnapshotBar = await bar.get();
      final nestedDocument =
          updatedSnapshotBar.data['nested'] as Map<String, dynamic>;
      expect(nestedDocument['field'], 123);

      final deletedSnapshotBaz = await baz.get();
      expect(deletedSnapshotBaz.exists, false);
    });

    ftest('Transaction handler returning void result', (firestore) async {
      final foo = firestore.collection('messages').document('foo');
      await foo.setData({'name': 'Foo'});

      final result = await firestore.runTransaction((tx) async {
        final snapshotFoo = await tx.get(foo);

        await tx.set(foo, {'name': snapshotFoo.data['name'] + 'o'});
        // not returning a map
      });
      expect(result, _test.isEmpty);

      final updatedSnapshotFoo = await foo.get();
      expect(updatedSnapshotFoo.data['name'], 'Fooo');
    });

    ftest('Transaction handler returning non-map result', (firestore) async {
      final foo = firestore.collection('messages').document('foo');
      await foo.setData({'name': 'Foo'});

      Future<dynamic> erroneousTransactionUsage() async {
        await firestore.runTransaction((tx) async {
          final snapshotFoo = await tx.get(foo);

          await tx.set(foo, {
            'name': snapshotFoo.data['name'] + 'oo',
          });
          // Although TransactionHandler's type signature does not specify
          // the return value type, it fails non-map return value.
          return 3;
        });
      }

      expect(erroneousTransactionUsage, _test.throwsA(_test.isA<TypeError>()));
    });

    // In Firestore Transaction, read operations must come before write operations
    // https://firebase.google.com/docs/firestore/manage-data/transactions#transactions
    ftest('Transaction: reads must come before writes', (firestore) async {
      final foo = firestore.collection('messages').document('foo');
      final bar = firestore.collection('messages').document('bar');
      await foo.setData({'name': 'Foo'});
      await bar.setData({'name': 'Bar'});

      Future<dynamic> erroneousTransactionUsage() async {
        await firestore.runTransaction((tx) async {
          final snapshotFoo = await tx.get(foo);

          await tx.set(foo, {
            'name': snapshotFoo.data['name'] + 'o',
          });
          // get (read operation) cannot come after set
          await tx.get(bar);
        });
      }

      expect(erroneousTransactionUsage,
          _test.throwsA(_test.isA<PlatformException>()));
    });

    ftest('Transaction: result map with invalid types', (firestore) async {
      // It's not documented, but runTransaction fails when certain data types
      // are present in the result map. It seems Cloud Firestore follows this
      // restriction in Firebase HttpsCallableReference, with exception of
      // Timestamp and DateTime:
      // https://firebase.google.com/docs/reference/android/com/google/firebase/functions/HttpsCallableReference#public-taskhttpscallableresult-call-object-data
      final badTypes = <dynamic>[
        firestore.collection('messages').document('foo'),
        BigInt.from(3),
        [1, 2, BigInt.from(3)],
        {
          'k1': {'k2': BigInt.from(3)}
        },
      ];

      for (final badValue in badTypes) {
        Future<dynamic> erroneousTransactionUsage() async {
          await firestore.runTransaction((tx) async {
            return {'bad': badValue};
          });
        }

        expect(erroneousTransactionUsage,
            _test.throwsA(_test.isA<PlatformException>()),
            reason: 'Value $badValue should be considered bad value');
      }
    });

    ftest('Transaction: result map with valid types', (firestore) async {
      final currentTime = DateTime.now();
      final timestamp = Timestamp.fromDate(currentTime);
      final geoPoint = GeoPoint(40.730610, -73.935242); // New York City
      final result = await firestore.runTransaction((tx) async {
        return <String, dynamic>{
          'null': null,
          'int': 1000000000000000000, // within 64 bits
          'double': 1.23,
          'bool': false,
          'String': 'foo',
          'List': [1, 2, 3],
          'Map': {'foo': 2},
          'DateTime': currentTime,
          'Timestamp': timestamp,
          'GeoPoint': geoPoint,
          'Blob': Blob(utf8.encode('bytes')),
        };
      });
      expect(result['null'], null);
      expect(result['int'], 1000000000000000000);
      expect(result['double'], 1.23);
      expect(result['bool'], false);
      expect(result['String'], 'foo');
      expect(result['List'], [1, 2, 3]);
      expect(result['Map'], {'foo': 2});
      // It seems the DateTime is converted to TimeStamp losing precision.
      expect(
          result['DateTime'],
          within(
              from: currentTime,
              distance: 1,
              distanceFunction: (DateTime t1, DateTime t2) =>
                  t1.difference(t2).inMilliseconds));
      expect(result['Timestamp'], timestamp);
      expect(result['GeoPoint'], geoPoint);
      expect(result['Blob'], Blob(utf8.encode('bytes')));
    });
  });
}
