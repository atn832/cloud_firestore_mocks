import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_firestore_platform_interface/cloud_firestore_platform_interface.dart';
import 'package:mockito/mockito.dart';

import 'cloud_firestore_mocks_base.dart';
import 'mock_collection_reference.dart';
import 'mock_document_snapshot.dart';
import 'mock_field_value_platform.dart';
import 'util.dart';

class MockDocumentReference extends Mock implements DocumentReference {
  final String _documentId;
  final Map<String, dynamic> root;
  final Map<String, dynamic> rootParent;
  final Map<String, dynamic> snapshotStreamControllerRoot;
  final MockFirestoreInstance _firestore;

  /// Path from the root to this document. For example "users/USER0004/friends/FRIEND001"
  final String _path;

  MockDocumentReference(this._firestore, this._path, this._documentId,
      this.root, this.rootParent, this.snapshotStreamControllerRoot);

  // ignore: unused_field
  final DocumentReferencePlatform _delegate = null;

  @override
  Firestore get firestore => _firestore;

  @override
  String get documentID => _documentId;

  @override
  String get path => _path;

  @override
  CollectionReference parent() {
    final segments = _path.split('/');
    // For any document reference, segment length is more than 1
    final segmentLength = segments.length;
    final parentSegments = segments.sublist(0, segmentLength - 1);
    final parentPath = parentSegments.join('/');
    return _firestore.collection(parentPath);
  }

  @override
  CollectionReference collection(String collectionPath) {
    final path = [_path, collectionPath].join('/');
    return MockCollectionReference(
        _firestore,
        path,
        getSubpath(root, collectionPath),
        getSubpath(snapshotStreamControllerRoot, collectionPath));
  }

  @override
  Future<void> updateData(Map<String, dynamic> data) {
    validateDocumentValue(data);
    // Copy data so that subsequent change to `data` should not affect the data
    // stored in mock document.
    final copy = deepCopy(data);
    copy.forEach((key, value) {
      // document == root if key is not a composite key
      final document = _findNestedDocumentToUpdate(key);
      if (document != root) {
        // Example, key: 'foo.bar.username', get 'username' field
        key = key.split('.').last;
      }
      if (value is FieldValue) {
        final valueDelegate = FieldValuePlatform.getDelegate(value);
        final fieldValuePlatform = valueDelegate as MockFieldValuePlatform;
        final fieldValue = fieldValuePlatform.value;
        fieldValue.updateDocument(document, key);
      } else if (value is DateTime) {
        document[key] = Timestamp.fromDate(value);
      } else {
        document[key] = value;
      }
    });
    _firestore.saveDocument(path);
    return Future.value(null);
  }

  Map<String, dynamic> _findNestedDocumentToUpdate(String key) {
    final compositeKeyElements = key.split('.');
    if (compositeKeyElements.length == 1) {
      // This is not a composite key
      return root;
    }

    Map<String, dynamic> document = root;

    // For N elements, iterate until N-1 element.
    // For example, key: "foo.bar.baz", this method return the document pointed by
    // 'foo.bar'. The document will be updated by the caller on 'baz' field
    final keysToIterate =
        compositeKeyElements.sublist(0, compositeKeyElements.length - 1);
    for (String keyElement in keysToIterate) {
      if (!document.containsKey(keyElement) || !(document[keyElement] is Map)) {
        document[keyElement] = <String, dynamic>{};
        document = document[keyElement];
      } else {
        document = document[keyElement] as Map<String, dynamic>;
      }
    }
    return document;
  }

  @override
  Future<void> setData(Map<String, dynamic> data, {bool merge = false}) {
    if (!merge) {
      root.clear();
    }
    return updateData(data);
  }

  @override
  Future<DocumentSnapshot> get({Source source = Source.serverAndCache}) {
    return Future.value(
        MockDocumentSnapshot(this, _documentId, root, _exists()));
  }

  bool _exists() {
    return _firestore.hasSavedDocument(_path);
  }

  @override
  Future<void> delete() {
    rootParent.remove(documentID);
    _firestore.removeSavedDocument(path);
    return Future.value();
  }

  @override
  Stream<DocumentSnapshot> snapshots({bool includeMetadataChanges = false}) {
    return Stream.value(
        MockDocumentSnapshot(this, _documentId, root, _exists()));
  }

  @override
  bool operator ==(dynamic o) =>
      o is DocumentReference && o.firestore == _firestore && o.path == _path;

  @override
  int get hashCode => _path.hashCode + _firestore.hashCode;
}
