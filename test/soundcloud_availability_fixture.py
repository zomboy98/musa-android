import json
import subprocess
import zipfile
from pathlib import Path

archive = Path(__file__).parents[1] / 'assets/bundled_extensions/soundcloud.sflx'
source = zipfile.ZipFile(archive).read('index.js').decode()
start = source.index('function checkAvailability(')
end = source.index('\nfunction download(', start)
fn = source[start:end]
start = source.index('function hasFullPlayableStream(')
end = source.index('\nfunction ', start + 1)
fn = source[start:end] + fn
match_start = source.index('function stripTrackTitleAnnotations(')
match_end = source.index('// EXPORTED API', match_start)
matching_functions = source[match_start:match_end]
js = '''const assert = require('assert');
let mock;
const log = {info(){}, debug(){}};
function fetchTrackData(id) { assert.equal(id, '12345'); return mock; }
function scGet() { return {collection: [mock]}; }
const matching = {
  compareStrings(a,b) { return String(a).trim().toLowerCase() === String(b).trim().toLowerCase() ? 1 : 0; },
  compareDuration(a,b) { return Math.abs(a-b) <= 3000; },
};
function trackCacheSet() {}
const utils = {};
''' + matching_functions + fn + '''
function run(t, source='soundcloud', id='12345') {mock=t; return checkAvailability('', '', '', {track:{provider_id:source,id}});}
const media={transcodings:[{}]};
assert.equal(run({id:'12345',streamable:true,media}).available,true);
assert.equal(run({id:'12345',streamable:true,access:'playable'}).available,true);
for (const access of ['preview','blocked','subscription', null, '']) assert.equal(run({id:'12345',streamable:true,access,media}).available,false);
assert.equal(run({id:'12345',streamable:false,media}).available,false);
assert.equal(run({id:'12345',streamable:true,media:{transcodings:[]}}).available,false);
assert.equal(run({id:'12345',streamable:true}).available,false);
assert.equal(run({id:'12345',streamable:true,media},'spotify').available,false);
assert.equal(run({id:'12345',streamable:true,media},'soundcloud','bad-id').available,false);
mock={id:'12345',streamable:true,media};
assert.equal(checkAvailability('', '', '', {spotify_id:'12345'}).available,false);
assert.equal(checkAvailability('', '', '', {spotify_id:'12345',track:{provider_id:'spotify',id:'12345'}}).available,false);
let candidates = [
 {id:'99999', title:'Wrong', user:{username:'Someone'}, duration:100000, streamable:true, media},
 {id:'12345', title:'Song', user:{username:'Artist'}, duration:100000, streamable:true, media},
];
const actualScGet = scGet; scGet = () => ({collection:candidates});
assert.equal(checkAvailability('', 'Song', 'Artist', {duration_ms:100000}).track_id,'12345');
assert.equal(checkAvailability('', 'Song', 'Artist', {duration_ms:130000}).available,false);
assert.equal(checkAvailability('', 'Song', 'Other', {duration_ms:100000}).available,false);
candidates[1].access='preview';
assert.equal(checkAvailability('', 'Song', 'Artist', {duration_ms:100000}).available,false);
candidates[1].access='blocked';
assert.equal(checkAvailability('', 'Song', 'Artist', {duration_ms:100000}).available,false);
console.log('adversarial direct ID and real matching function cases passed');
'''
subprocess.run(['node', '-e', js], check=True)
