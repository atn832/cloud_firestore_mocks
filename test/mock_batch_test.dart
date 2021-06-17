import 'dart:math';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

void main() async {
  final usersPath = 'users';

  Map<String, dynamic> userDocumentMock(String userId) {
    return {
      'id': userId,
      'updatedAt': DateTime.now(),
      'createdAt': DateTime.now(),
    };
  }

  List<dynamic> createUsers({required int times}) async {
    final userDataList = [];
    for (var i = 0; i < times; i++) {
      final userId = i.toString();
      userDataList.add(userDocumentMock(userId));
    }
    return userDataList;
  }

  group('batch', () {
    test('succees when create 500 documents at once.', () async {
      final firestore = FakeFirebaseFirestore();
      final userDataList = await createUsers(times: 500);
      final userDataListLength = userDataList.length;
      for (var i = 0; i < userDataListLength; i = i + 500) {
        final first = i;
        final last = min(i + 500, userDataListLength);

        final selectUserDataList = userDataList.getRange(first, last);
        final batch = firestore.batch();
        for (final userData in selectUserDataList) {
          final documentRef =
              firestore.collection(usersPath).doc(userData['id']);
          batch.set(documentRef, userData);
        }
        await batch.commit();
      }
      final result = await firestore.collection(usersPath).get();
      expect(result.docs.length, 500);
    });

    test('fail when create 501 documents at once.', () async {
      final firestore = FakeFirebaseFirestore();
      final userDataList = await createUsers(times: 501);
      final batch = firestore.batch();
      for (final userData in userDataList) {
        final documentRef = firestore.collection(usersPath).doc(userData['id']);
        batch.set(documentRef, userData);
      }
      expect(() => batch.commit(), throwsException);
    });
  });
}

