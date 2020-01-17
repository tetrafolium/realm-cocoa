////////////////////////////////////////////////////////////////////////////
//
// Copyright 2015 Realm Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
////////////////////////////////////////////////////////////////////////////

#if canImport(Combine)
import XCTest
import RealmSwift

class BackLink: Object {
    let list = List<Linked>()
}
class Linked: Object {
    let backlink = LinkingObjects(fromType: BackLink.self, property: "list")
}

@available(OSX 10.15, watchOS 6.0, iOS 13.0, iOSApplicationExtension 13.0, OSXApplicationExtension 10.15, *)
class CombineTests: TestCase {
    var realm: Realm! = nil

    override class var defaultTestSuite: XCTestSuite {
        if #available(OSX 10.15, watchOS 6.0, iOS 13.0, iOSApplicationExtension 13.0, OSXApplicationExtension 10.15, *) {
            return super.defaultTestSuite
        }
        return XCTestSuite(name: "CombineTests")
    }

    override func setUp() {
        super.setUp()
        realm = try! Realm(configuration: Realm.Configuration(inMemoryIdentifier: "test"))
        realm.beginWrite()
    }

    override func tearDown() {
        realm = nil
        super.tearDown()
    }

    func getObject(_ obj: SwiftKVOObject) -> (SwiftKVOObject, SwiftKVOObject) {
        realm.add(obj)
        try! realm.commitWrite()
        return (obj, obj)
    }

    func testObjectWillChange() {
        let obj = try! realm.write { realm.create(SwiftIntObject.self, value: []) }
        let exp = XCTestExpectation(description: "sink will receive objects")

        let cancellable = RealmPublisher(obj).sink { (o: SwiftIntObject) in
            XCTAssertEqual(obj, o)
            exp.fulfill()
        }

        try! realm.write { obj.intCol = 1 }

        wait(for: [exp], timeout: 1)
        cancellable.cancel()
    }

    func testListWillChange() {
        let exp = XCTestExpectation(description: "sink will receive objects")
        let (obj, _) = getObject(SwiftKVOObject())

        let cancellable = obj.arrayBool.objectWillChange.sink {
            XCTAssertEqual(obj.arrayBool, $0)
            exp.fulfill()
        }

        try! realm.write { obj.arrayBool.append(false) }

        wait(for: [exp], timeout: 10)
        cancellable.cancel()
    }

    func testResultsWillChange() {
        let exp = XCTestExpectation(description: "sink will receive objects")

        let (obj, _) = getObject(SwiftKVOObject())
        let results = obj.arrayCol.filter("int64Col == 4")

        let cancellable = results.objectWillChange.sink {
            XCTAssertEqual(obj.arrayCol[0], $0[0])
            exp.fulfill()
        }

        try! realm.write { obj.arrayCol.append(SwiftKVOObject()) }

        wait(for: [exp], timeout: 10)
        cancellable.cancel()
    }

    func testLinkingObjectsWillChange() {
        let exp = XCTestExpectation(description: "sink will receive objects")

        let kvoBackLink = BackLink()
        let kvoLinked = Linked()

        kvoBackLink.list.append(kvoLinked)
        realm.add(kvoBackLink)
        try! realm.commitWrite()

        let cancellable = kvoLinked.backlink.objectWillChange.sink { (_: LinkingObjects<BackLink>) in
            //            XCTAssertEqual(kvoLinked.backlink, $0)
            exp.fulfill()
        }

        try! realm.write { kvoBackLink.list.append(Linked()) }

        wait(for: [exp], timeout: 10)
        cancellable.cancel()
    }
}

#endif // canImport(Combine)
