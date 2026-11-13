import XCTest
@testable import OneSatActions

/// Ports `packages/actions/test/ordfsManifest.test.ts` (`buildOrdfsDirManifest`).
final class OrdfsDirTreeTests: XCTestCase {
    private func tree(_ paths: [String]) throws -> OrdfsDirTree {
        try OrdfsDirTree.build(paths: paths)
    }

    func test_laysOutAFlatDirectoryOfRootLevelFiles() throws {
        let tree = try tree(["README.md", "index.ts"])
        XCTAssertEqual(tree.files.map(\.path), ["README.md", "index.ts"])
        XCTAssertEqual(tree.files.map(\.vout), [0, 1])
        XCTAssertEqual(tree.subdirs, [])
        XCTAssertEqual(tree.root.dictionary, ["README.md": "_0", "index.ts": "_1"])
        XCTAssertEqual(tree.manifestVout, 2)
        XCTAssertEqual(tree.manifestContentType, "ord-fs/json")
    }

    func test_throwsOnADuplicateRootLevelPath() {
        XCTAssertThrowsError(try tree(["a.md", "a.md"])) { error in
            XCTAssertTrue((error as? OrdfsDirTreeError)?.message.contains("path collision") == true)
        }
    }

    func test_throwsWhenARootFileCollidesWithASubdirectoryName() {
        XCTAssertThrowsError(try tree(["a", "a/b.md"])) { error in
            XCTAssertTrue((error as? OrdfsDirTreeError)?.message.contains("path collision") == true)
        }
        XCTAssertThrowsError(try tree(["a/b.md", "a"])) { error in
            XCTAssertTrue((error as? OrdfsDirTreeError)?.message.contains("path collision") == true)
        }
    }

    func test_throwsOnADuplicateNestedPath() {
        XCTAssertThrowsError(try tree(["refs/api.md", "refs/api.md"])) { error in
            XCTAssertEqual(
                (error as? OrdfsDirTreeError)?.message,
                "ord-fs directory path collision: \"api.md\" conflicts with an existing entry in directory \"refs/\""
            )
        }
    }

    func test_throwsWhenAPathNestsDeeperThanTheServerTraverses() throws {
        let tooDeep = (0..<8).map { "d\($0)" }.joined(separator: "/") + "/leaf.md"
        XCTAssertThrowsError(try tree([tooDeep])) { error in
            XCTAssertTrue((error as? OrdfsDirTreeError)?.message.contains("too deep") == true)
        }
        let deepest = (0..<7).map { "d\($0)" }.joined(separator: "/") + "/leaf.md"
        XCTAssertEqual(try tree([deepest]).subdirs.count, 7)
    }

    func test_buildsASubdirectoryManifestForNestedFiles() throws {
        let tree = try tree(["SKILL.md", "refs/api.md", "refs/cli.md"])
        XCTAssertEqual(tree.files.map(\.vout), [0, 1, 2])
        XCTAssertEqual(tree.subdirs.count, 1)
        XCTAssertEqual(tree.subdirs[0].path, "refs")
        XCTAssertEqual(tree.subdirs[0].vout, 3)
        XCTAssertEqual(tree.subdirs[0].manifest.dictionary, ["api.md": "_1", "cli.md": "_2"])
        XCTAssertEqual(tree.root.dictionary, ["SKILL.md": "_0", "refs": "_3"])
        XCTAssertEqual(tree.manifestVout, 4)
    }

    func test_buildsAManifestPerLevelForDeeplyNestedPaths() throws {
        let tree = try tree(["docs/v1/api.md", "docs/v2/api.md"])
        XCTAssertEqual(tree.subdirs.map(\.path), ["docs", "docs/v1", "docs/v2"])
        XCTAssertEqual(tree.subdirs.map(\.vout), [2, 3, 4])
        XCTAssertEqual(tree.subdirs[0].manifest.dictionary, ["v1": "_3", "v2": "_4"])
        XCTAssertEqual(tree.subdirs[1].manifest.dictionary, ["api.md": "_0"])
        XCTAssertEqual(tree.subdirs[2].manifest.dictionary, ["api.md": "_1"])
        XCTAssertEqual(tree.root.dictionary, ["docs": "_2"])
        XCTAssertEqual(tree.manifestVout, 5)
    }

    func test_assignsSubdirectoryVoutsInFirstSeenOrder() throws {
        let tree = try tree(["a/one.md", "b/two.md", "a/three.md"])
        XCTAssertEqual(tree.subdirs.map(\.path), ["a", "b"])
        XCTAssertEqual(tree.subdirs.map(\.vout), [3, 4])
        XCTAssertEqual(tree.subdirs[0].manifest.dictionary, ["one.md": "_0", "three.md": "_2"])
        XCTAssertEqual(tree.subdirs[1].manifest.dictionary, ["two.md": "_1"])
        XCTAssertEqual(tree.root.dictionary, ["a": "_3", "b": "_4"])
        XCTAssertEqual(tree.manifestVout, 5)
    }

    func test_packageLayoutMatchesTheRegistryCharacterization() throws {
        let tree = try tree(["SKILL.md", "refs/api.md"])
        XCTAssertEqual(tree.root.dictionary, ["SKILL.md": "_0", "refs": "_2"])
        XCTAssertEqual(tree.subdirs[0].manifest.dictionary, ["api.md": "_1"])
        XCTAssertEqual(tree.manifestVout, 3)
    }

    // MARK: JSON bytes (JSON.stringify parity, checked against Node)

    func test_jsonKeepsInsertionOrder() throws {
        let tree = try tree(["SKILL.md", "refs/api.md", "LICENSE"])
        XCTAssertEqual(
            String(decoding: tree.root.jsonBytes, as: UTF8.self),
            #"{"SKILL.md":"_0","refs":"_3","LICENSE":"_2"}"#
        )
    }

    func test_jsonOrdersArrayIndexKeysFirstLikeJavaScript() throws {
        let tree = try tree(["b.md", "10", "2", "a/x", "01", "4294967295", "4294967294"])
        XCTAssertEqual(
            String(decoding: tree.root.jsonBytes, as: UTF8.self),
            #"{"2":"_2","10":"_1","4294967294":"_6","b.md":"_0","a":"_7","01":"_4","4294967295":"_5"}"#
        )
    }

    func test_jsonEscapesLikeJSONStringify() {
        let manifest = OrdfsJSONManifest(entries: [
            .init(name: "q\"\\\n\u{01}\u{1f}\té\u{2028}", ref: "_0"),
        ])
        XCTAssertEqual(
            manifest.jsonBytes,
            Array("7b22715c225c5c5c6e5c75303030315c75303031665c74c3a9e280a8223a225f30227d".hexBytes)
        )
    }

    func test_namesCompareByBytesNotCanonicalEquivalence() throws {
        // "é" precomposed and decomposed are distinct keys in JavaScript.
        let tree = try tree(["\u{e9}.md", "e\u{301}.md"])
        XCTAssertEqual(tree.root.entries.count, 2)
    }
}

private extension String {
    var hexBytes: [UInt8] {
        var bytes: [UInt8] = []
        var index = startIndex
        while index < endIndex {
            let next = self.index(index, offsetBy: 2)
            bytes.append(UInt8(self[index..<next], radix: 16) ?? 0)
            index = next
        }
        return bytes
    }
}
