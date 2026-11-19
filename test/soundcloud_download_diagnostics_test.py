import subprocess
from pathlib import Path

source = (Path(__file__).parents[1] / 'extensions_source/soundcloud/index.js').read_text(encoding='utf-8')
start = source.index('function download(trackID,')
end = source.index('\nfunction downloadCancelled()', start)
rank_start = source.index('function transcodingFormat(')
rank_end = source.index('\nfunction resolveStreamURL(', rank_start)
http_start = source.index('function soundCloudResponseError(')
http_end = source.index('\nfunction fetchClientId(', http_start)
js = r'''
const assert = require('assert');
let logs = [], candidates = [], fail = false, failApi = false;
const log = {info(){}, warn(...args){ logs.push(args.join(' ')); }};
function hasFullPlayableStream(){ return true; }
function fetchTrackData(){ throw new Error('https://private/?token=secret'); }
function ensureClientId() { if (failApi) throw new Error('https://private/?token=secret'); }
function audioOutputPath(){ return 'output'; }
function userAgentForURL(){ return 'test'; }
function downloadCancelled(){ return false; }
function resolveStreamURL(){ if (fail) throw new Error('secret-sensitive-detail'); return 'unused'; }
const file = {download(){ return {success:true}; }};
''' + source[rank_start:rank_end] + source[start:end] + r'''
function run() { return download('id', 'aac_160', 'output', null, {preparedContext:{track:{id:'id'}}}); }
failApi=true;
const apiFailed=run();
assert.equal(apiFailed.error_type,'api_error');
assert(!apiFailed.error_message.includes('secret'));
failApi=false;
const fetchFailed = download('id', 'aac_160', 'output', null, {});
assert.equal(fetchFailed.error_type, 'api_error');
assert(!fetchFailed.error_message.includes('secret'));
assert.equal(run().success, false);
assert(logs.some(s => s.includes('category=no_candidates')));
assert(logs.some(s => s.includes('total=0')));
logs=[]; candidates=[{url:'private',format:{protocol:'progressive',mime_type:'audio/mpeg'}}]; fail=true;
// The prepared track receives the candidates rather than a mocked ranker.
function runCandidates() { return download('id', 'aac_160', 'output', null, {preparedContext:{track:{id:'id',media:{transcodings:candidates}}}}); }
const failed = runCandidates();
assert.equal(failed.success, false);
assert.equal(failed.error_type, 'download_error');
assert(!failed.error_message.includes('secret-sensitive-detail'));
assert(logs.some(s => s.includes('stage=resolve')));
assert(!logs.join(' ').includes('secret-sensitive-detail'));
let rows = [null, {}, {url:'private',format:{},snipped:true},
 {url:'private',format:{},preset:'preview'},
 {url:'private',format:{protocol:'unknown',mime_type:'audio/mpeg'}},
 {url:'private',format:{protocol:'hls',mime_type:'unknown'}}];
logs=[]; candidates=rows; runCandidates();
assert(logs.some(s => s.includes('total=6 missing=2 preview=2 protocol=1 format=1')));
assert(!logs.join(' ').includes('private'));
const item=(mime, protocol='progressive')=>({url:'private',format:{protocol,mime_type:mime}});
const selected=rankTranscodings([item('audio/mpeg'),item('audio/opus','hls'),item('audio/mp4')], 'aac');
assert.equal(selected.length,3);
assert.deepEqual(selected.map(transcodingFormat),['m4a','opus','mp3']);
// The first failed candidate still falls back to the second.
let attempts=0;
resolveStreamURL = function(){ if (++attempts === 1) throw new Error('https://private/?token=secret'); return 'unused'; };
candidates=[item('audio/mp4'),item('audio/mpeg')];
assert.equal(runCandidates().success,true);
assert.equal(attempts,2);
console.log('SoundCloud download diagnostics passed');
'''
subprocess.run(['node', '-e', js], check=True)

http_js = r'''
const assert = require('assert');
let logs = [], calls = 0;
const log = {warn(...args){logs.push(args.join(' '));}};
const utils = {sleep(){return true;}};
const http = {get(){calls++; throw new Error('https://private/?token=secret');}};
''' + source[http_start:http_end] + r'''
const result = soundCloudGet('unused', {});
assert.equal(calls, 2);
assert(result.error.includes('token=secret')); // Internal error still drives retry policy.
assert(!logs.join(' ').includes('private'));
assert(!logs.join(' ').includes('secret'));
assert(logs.join(' ').includes('network error'));
'''
subprocess.run(['node', '-e', http_js], check=True)
