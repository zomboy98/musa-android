"""Exercise the packaged extension lifecycle without network or user data."""
import subprocess
import zipfile
from pathlib import Path

archive = Path(__file__).parents[1] / 'assets/bundled_extensions/soundcloud.sflx'
source = zipfile.ZipFile(archive).read('index.js').decode()
source = source[:source.index('function trackCacheGet(')]
test = '''
const assert = require('assert');
let old = JSON.stringify({clientId:'synthetic', clientIdExpiry:Date.now()+60000, scVersion:'test'});
let saved = old, writes = 0;
const storage = {get(){return saved;},set(k,v){writes++;saved=v;}};
const log = {info(){}};
''' + source + '''
cleanup();
assert.equal(writes,0, 'validation-only and disabled cleanup must not write');
assert.equal(saved,old);
initialize({});
cleanup();
assert.equal(writes,0, 'initialized cleanup must not rewrite unchanged state');
assert.equal(JSON.parse(saved).clientId,'synthetic');
cleanup();
assert.equal(writes,0, 'repeated or disabled cleanup must not write');
saved='{broken'; initialize({}); cleanup(); assert.equal(saved,'{broken'); assert.equal(writes,0);
saved=JSON.stringify({clientId:'expired',clientIdExpiry:1}); let expired=saved;
initialize({}); cleanup(); assert.equal(saved,expired); assert.equal(writes,0);
storage.get=()=>{throw new Error('unavailable');}; initialize({}); cleanup();
assert.equal(saved,expired); assert.equal(writes,0);
state.clientId='new-synthetic'; persistSoundCloudState();
assert.equal(writes,1); assert.equal(JSON.parse(saved).clientId,'new-synthetic');
console.log('lifecycle checks passed');
'''
subprocess.run(['node', '-e', test], check=True)
