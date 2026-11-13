/// Vectors produced by running the TypeScript sources of `b-open-io/1sat-sdk` (commit 71fd3ba):
/// `ordinalTagsFromMetadata`, `nameFromMap`, `displayNameForCi`, `contentTypeTag`,
/// `parseMapSubTypeData` and `formatOrdinalOutpoint` from `@1sat/types`, and `OrdfsClient` from
/// `@1sat/client` with a recording `fetch`. Inputs and outputs are as TS saw and returned them.
enum OrdfsFixtures {
    static let json = #"""
{
 "tagCases": [
  {
   "metadata": {
    "origin": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.0",
    "contentType": "image/png; charset=binary",
    "map": {
     "app": "1sat.market",
     "name": "Ape #3",
     "subType": "collectionItem",
     "subTypeData": "{\"collectionId\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.0\",\"mintNumber\":3}"
    }
   },
   "tags": [
    "origin:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0",
    "collection:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb_0",
    "app:1sat.market",
    "type:image/png"
   ]
  },
  {
   "metadata": {
    "origin": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_1",
    "contentType": "image/webp",
    "map": {
     "subTypeData": {
      "collection": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb_2"
     }
    }
   },
   "tags": [
    "origin:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_1",
    "collection:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb_2",
    "type:image/webp"
   ]
  },
  {
   "metadata": {
    "origin": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.0",
    "map": {
     "collectionId": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc_0",
     "collection": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd_0",
     "subTypeData": {
      "collectionId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb_0"
     }
    }
   },
   "tags": [
    "origin:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0",
    "collection:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc_0"
   ]
  },
  {
   "metadata": {
    "origin": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.0",
    "map": {
     "collectionId": 7,
     "collection": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd.4"
    }
   },
   "tags": [
    "origin:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0",
    "collection:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd_4"
   ]
  },
  {
   "metadata": {
    "origin": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.0",
    "map": {
     "content": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc.1"
    },
    "parent": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd_0"
   },
   "tags": [
    "origin:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0",
    "content:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc_1"
   ]
  },
  {
   "metadata": {
    "origin": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.0",
    "map": {
     "content": ""
    },
    "parent": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd_0"
   },
   "tags": [
    "origin:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0"
   ]
  },
  {
   "metadata": {
    "origin": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.0",
    "parent": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd.9"
   },
   "tags": [
    "origin:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0",
    "content:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd_9"
   ]
  },
  {
   "metadata": {
    "origin": "",
    "contentType": "text/plain"
   },
   "fallbackOrigin": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.5",
   "tags": [
    "origin:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb_5",
    "type:text/plain"
   ]
  },
  {
   "metadata": null,
   "fallbackOrigin": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.5",
   "tags": [
    "origin:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb_5"
   ]
  },
  {
   "metadata": {
    "origin": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.0",
    "contentType": " ; x=y",
    "map": {
     "subTypeData": "not json"
    }
   },
   "tags": [
    "origin:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0"
   ]
  },
  {
   "metadata": {
    "origin": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.0",
    "map": {
     "subTypeData": "[{\"collectionId\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.0\"}]"
    }
   },
   "tags": [
    "origin:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0"
   ]
  },
  {
   "metadata": {
    "origin": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.0",
    "map": {
     "collectionId": "",
     "subTypeData": {
      "collectionId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.0"
     }
    }
   },
   "tags": [
    "origin:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0"
   ]
  },
  {
   "metadata": {
    "contentType": "application/op-ns"
   },
   "tags": [
    "type:application/op-ns"
   ]
  }
 ],
 "nameCases": [
  {
   "map": {
    "name": "Plain"
   },
   "name": "Plain"
  },
  {
   "map": {
    "name": "",
    "subTypeData": "{\"name\":\"From STD\"}"
   },
   "name": "From STD"
  },
  {
   "map": {
    "subTypeData": {
     "name": "Object STD"
    }
   },
   "name": "Object STD"
  },
  {
   "map": {
    "name": 5,
    "subTypeData": {
     "name": ""
    }
   },
   "name": null
  },
  {
   "map": null,
   "name": null
  }
 ],
 "display": [
  {
   "input": "  hello  ",
   "output": "hello"
  },
  {
   "input": "   ",
   "output": null
  },
  {
   "input": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
   "output": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
  },
  {
   "input": " ééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééz",
   "output": "éééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééé"
  }
 ],
 "types": [
  {
   "input": "image/png",
   "output": "type:image/png"
  },
  {
   "input": "text/html; charset=utf-8",
   "output": "type:text/html"
  },
  {
   "input": "",
   "output": null
  },
  {
   "input": ";",
   "output": null
  },
  {
   "input": " application/json ",
   "output": "type:application/json"
  }
 ],
 "outpoints": [
  {
   "input": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.0",
   "output": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0"
  },
  {
   "input": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_12",
   "output": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_12"
  },
  {
   "input": " aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.3 ",
   "output": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_3"
  },
  {
   "input": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
   "output": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  },
  {
   "input": "x.y.z",
   "output": "x_y.z"
  },
  {
   "input": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA.1",
   "output": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA_1"
  }
 ],
 "std": [
  {
   "map": {
    "subTypeData": "{\"a\":1}"
   },
   "output": {
    "a": 1
   }
  },
  {
   "map": {
    "subTypeData": " "
   },
   "output": null
  },
  {
   "map": {
    "subTypeData": "[1]"
   },
   "output": null
  },
  {
   "map": {
    "subTypeData": {
     "b": "x"
    }
   },
   "output": {
    "b": "x"
   }
  },
  {
   "map": {
    "subTypeData": [
     "x"
    ]
   },
   "output": null
  },
  {
   "map": {},
   "output": null
  }
 ],
 "urlCases": [
  {
   "outpoint": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0",
   "options": {},
   "url": "https://api.1sat.app/content/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0"
  },
  {
   "outpoint": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0",
   "options": {
    "seq": 0
   },
   "url": "https://api.1sat.app/content/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0:0"
  },
  {
   "outpoint": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0",
   "options": {
    "seq": -1,
    "map": true,
    "parent": false,
    "raw": true
   },
   "url": "https://api.1sat.app/content/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0:-1?map=true&raw=true"
  },
  {
   "outpoint": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
   "options": {
    "parent": true
   },
   "url": "https://api.1sat.app/content/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa?parent=true"
  }
 ],
 "calls": [
  {
   "url": "https://api.1sat.app/1sat/ordfs/metadata",
   "method": "POST",
   "contentType": "application/json",
   "body": "{\"outpoints\":[\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0:-2\",\"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc_1:-2\"]}"
  },
  {
   "url": "https://api.1sat.app/1sat/ordfs/metadata/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0:-1",
   "method": "GET",
   "contentType": null,
   "body": null
  },
  {
   "url": "https://api.1sat.app/1sat/ordfs/metadata/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0",
   "method": "GET",
   "contentType": null,
   "body": null
  }
 ],
 "bulk": {
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0:-2": {
   "outpoint": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0",
   "origin": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb_0",
   "sequence": 2,
   "contentType": "image/png",
   "contentLength": 10,
   "map": {
    "name": "N"
   }
  },
  "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc_1:-2": null
 }
}
"""#
}
