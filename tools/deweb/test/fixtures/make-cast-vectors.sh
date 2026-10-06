#!/bin/sh
# Writes cast-vectors.json: calldata and return data encoded by Foundry's `cast`, the reference the
# hand-written codec in src/abi.ts is tested against (test/abi.test.ts). Needs no network.
#   sh tools/deweb/test/fixtures/make-cast-vectors.sh > tools/deweb/test/fixtures/cast-vectors.json
C=0x00000000000000000000000000000000000000c1
H=0x1111111111111111111111111111111111111111111111111111111111111111
LONG='notes/a-path-longer-than-thirty-two-bytes/site.webmanifest'
cat <<JSON
{
  "container": "$C",
  "hash": "$H",
  "longPath": "$LONG",
  "putFile": "$(cast calldata 'putFile(address,string,string,bytes32,bytes)' $C 'assets/a b.js' 'text/javascript; charset=utf-8' $H 0xdeadbeef00)",
  "putFileEmpty": "$(cast calldata 'putFile(address,string,string,bytes32,bytes)' $C 'e' 'application/manifest+json; charset=utf-8' $H 0x)",
  "appendChunk": "$(cast calldata 'appendChunk(address,string,uint256,bytes)' $C "$LONG" 7 0x0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f2021)",
  "removeFile": "$(cast calldata 'removeFile(address,string)' $C 'index.html')",
  "setFallback": "$(cast calldata 'setFallback(address,string)' $C 'index.html')",
  "bind": "$(cast calldata 'bind(string,address,uint256)' '1.2.275.tape' $C 3)",
  "open": "$(cast calldata 'open(address,uint256)' $C 12)",
  "isLive": "$(cast calldata 'isLive(string,address)' '1.2.275.tape' $C)",
  "readRange": "$(cast calldata 'readRange(address,string,uint256,uint256)' $C 'big.bin' 98304 98304)",
  "fileInfo": "$(cast calldata 'fileInfo(address,string)' $C 'index.html')",
  "read": "$(cast calldata 'read(address,string)' $C 'index.html')",
  "pathsRange": "$(cast calldata 'pathsRange(address,uint256,uint256)' $C 200 200)",
  "accountOf": "$(cast calldata 'accountOf(address,uint256)' $C 12)",
  "canEdit": "$(cast calldata 'canEdit(address,address)' $C $C)",
  "fileInfoReturn": "$(cast abi-encode 'f(uint32,string,bytes32,uint40,uint256)' 60000 'application/octet-stream' $H 1791145036 3)",
  "stringArrayReturn": "$(cast abi-encode 'f(string[])' "[\"index.html\",\"assets/app.js\",\"$LONG\",\"\"]")",
  "bytesReturn": "$(cast abi-encode 'f(bytes)' 0x00ff10)",
  "stringReturn": "$(cast abi-encode 'f(string)' 'index.html')"
}
JSON
