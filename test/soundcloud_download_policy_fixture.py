import subprocess
import zipfile
from pathlib import Path

archive = Path(__file__).parents[1] / 'assets/bundled_extensions/soundcloud.sflx'
source = zipfile.ZipFile(archive).read('index.js').decode()
start = source.index('function download(')
end = source.index('\nfunction downloadCancelled(', start)
download = source[start:end]
start = source.index('function resolveStreamURL(')
end = source.index('\nfunction ', start + 1)
resolver = source[start:end]
helper = ''
if 'function hasFullPlayableStream(' in source:
    start = source.index('function hasFullPlayableStream(')
    end = source.index('\nfunction ', start + 1)
    helper = source[start:end]
script = '''
const assert=require('assert');
const log={info(){},warn(){}}; let calls=0;
function ensureClientId(){calls++;}
function rankTranscodings(){return [];}
''' + helper + download + resolver + '''
const media={transcodings:[{}]};
for(const access of [null,'','preview','blocked']) {
 calls=0; const result=download('12345','', '',null,{preparedContext:{track:{id:'12345',streamable:true,access,media}}});
 assert.equal(result.success,false); assert.equal(calls,0);
}
for(const track of [{id:'12345',streamable:true,media}, {id:'12345',streamable:true,access:'playable',media}]) {
 calls=0; download('12345','', '',null,{preparedContext:{track}}); assert.equal(calls,1);
}
for(const track of [{id:'12345',streamable:true}, {id:'12345',streamable:false,media}]) {
 calls=0; download('12345','', '',null,{preparedContext:{track}}); assert.equal(calls,0);
}
let requests=0, updated;
const state={clientId:'fixture',clientIdExpiry:0};
const http={get(){requests++;return {statusCode:403};}};
const utils={randomUserAgent(){return 'fixture';}};
function scGet(){return updated;}
function trackCacheSet(){}
for(const access of [null,'','preview','blocked']) {
 requests=0; updated={id:'12345',streamable:true,access,media};
 assert.throws(()=>resolveStreamURL({url:'https://example.test/audio'}, {id:'12345'}), /no longer playable/);
 assert.equal(requests,1);
}
console.log('download access checks passed');
'''
subprocess.run(['node', '-e', script], check=True)
