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
import Combine
import RealmSwift

class BackLink: Object {
    let list = List<Linked>()
}
class Linked: Object {
    let backlink = LinkingObjects(fromType: BackLink.self, property: "list")
}

// XCTest doesn't care about the @available on the class and will try to run
// the tests even on older versions. Putting this check inside `defaultTestSuite`
// results in a warning about it being redundant due to the encoding check, so
// it needs to be out of line.
func hasCombine() -> Bool {
    if #available(OSX 10.15, watchOS 6.0, iOS 13.0, iOSApplicationExtension 13.0, OSXApplicationExtension 10.15, *) {
        return true
    }
    return false
}

@available(OSX 10.15, watchOS 6.0, iOS 13.0, iOSApplicationExtension 13.0, OSXApplicationExtension 10.15, *)
class CombinePublisherTests: TestCase {
    var realm: Realm! = nil
    var token: AnyCancellable? = nil

    override class var defaultTestSuite: XCTestSuite {
        if hasCombine() {
            return super.defaultTestSuite
        }
        return XCTestSuite(name: "CombinePublisherTests")
    }

    override func setUp() {
        super.setUp()
        realm = try! Realm(configuration: Realm.Configuration(inMemoryIdentifier: "test"))
    }

    override func tearDown() {
        realm = nil
        if let token = token {
            token.cancel()
        }
        super.tearDown()
    }

    func testObjectChange() {
        let obj = try! realm.write { realm.create(SwiftIntObject.self, value: []) }
        let exp = XCTestExpectation()

        token = RealmPublisher(obj).sink { o in
            XCTAssertEqual(obj, o)
            exp.fulfill()
        }

        try! realm.write { obj.intCol = 1 }
        wait(for: [exp], timeout: 1)
    }

    func testObjectChangeSet() {
        let obj = try! realm.write { realm.create(SwiftIntObject.self, value: []) }
        let exp = XCTestExpectation()

        token = RealmChangePublisher(obj).sink { (o, change) in
            XCTAssertEqual(obj, o)
            if case .change(let properties) = change {
                XCTAssertEqual(properties.count, 1)
                XCTAssertEqual(properties[0].name, "intCol")
                XCTAssertNil(properties[0].oldValue)
                XCTAssertEqual(properties[0].newValue as? Int, 1)
            }
            else {
                XCTFail("Expected .change but got \(change)")
            }
            exp.fulfill()
        }

        try! realm.write { obj.intCol = 1 }
        wait(for: [exp], timeout: 1)
    }

    func testObjectDelete() {
        let obj = try! realm.write { realm.create(SwiftIntObject.self, value: []) }
        let exp = XCTestExpectation()

        token = RealmPublisher(obj).sink(receiveCompletion: { _ in exp.fulfill() },
                                         receiveValue: { _ in })

        try! realm.write { realm.delete(obj) }
        wait(for: [exp], timeout: 1)
    }

    func testFrozenObject() {
        let obj = try! realm.write { realm.create(SwiftIntObject.self, value: []) }
        let exp = XCTestExpectation()

        token = RealmPublisher(obj, freeze: true).collect().sink { arr in
            XCTAssertEqual(arr.count, 10)
            for i in 0..<10 {
                XCTAssertEqual(arr[i].intCol, i + 1)
            }
            exp.fulfill()
        }

        for _ in 0..<10 {
            try! realm.write { obj.intCol += 1 }
        }
        try! realm.write { realm.delete(obj) }
        wait(for: [exp], timeout: 1)
    }

    func testFrozenObjectSchedulers() {
        let obj = try! realm.write { realm.create(SwiftIntObject.self, value: []) }
        let exp = XCTestExpectation()

        token = RealmPublisher(obj, freeze: true)
            .subscribe(on: DispatchQueue.global())
            .receive(on: DispatchQueue.global())
//            .receive(on: RunLoop.main)
            .collect()
            .sink { arr in
                XCTAssertEqual(arr.count, 10)
                for i in 0..<10 {
                    XCTAssertEqual(arr[i].intCol, i + 1)
                }
                exp.fulfill()
        }

        for _ in 0..<10 {
            try! realm.write { obj.intCol += 1 }
        }
        try! realm.write { realm.delete(obj) }
        wait(for: [exp], timeout: 1)
    }

    func testFrozenObjectChangeSet() {
        let obj = try! realm.write { realm.create(SwiftIntObject.self, value: []) }
        let exp = XCTestExpectation()

        token = RealmChangePublisher(obj, freeze: true)
            .sink { (o, change) in
            XCTAssertEqual(obj, o)
            if case .change(let properties) = change {
                XCTAssertEqual(properties.count, 1)
                XCTAssertEqual(properties[0].name, "intCol")
                XCTAssertNil(properties[0].oldValue)
                XCTAssertEqual(properties[0].newValue as? Int, 1)
            }
            else {
                XCTFail("Expected .change but got \(change)")
            }
            exp.fulfill()
        }

        try! realm.write { obj.intCol = 1 }
        wait(for: [exp], timeout: 1)
    }

    /*
    func testList() {
        let exp = XCTestExpectation(description: "sink will receive objects")
        let obj = try! realm.write { realm.create(SwiftIntObject.self, value: []) }

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

        let obj = try! realm.write { realm.create(SwiftIntObject.self, value: []) }
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
 */
}

#endif // canImport(Combine)
