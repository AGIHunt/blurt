// Run the shipped inline script with controlled HTTP responses and debounce timers.
// No browser installation, network or npm dependencies are required.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const html = fs.readFileSync(path.join(__dirname, '../skills/blurt/scripts/review.html'), 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1].replace(/\nload\(\);\s*$/, '');
const initial = {items: [{id: 'I-1', kind: 'issue', title: 'Edited', status: 'draft', _touched: true},
  {id: 'I-2', kind: 'note', title: 'Dropped', status: 'deleted', _dropped: true}]};
const flush = () => new Promise(resolve => setImmediate(resolve));
const deferred = () => {let resolve, reject; const promise = new Promise((a, b) => {resolve = a; reject = b});
  return {promise, resolve, reject}};

function page(fetch) {
  const nodes = new Map(), timers = new Map();
  let nextTimer = 0;
  function node(selector) {
    if (!nodes.has(selector)) {
      const classes = new Set();
      nodes.set(selector, {textContent: '', disabled: false, hidden: false, inert: false,
        style: {}, dataset: {}, addEventListener() {}, blur() {},
        classList: {add: x => classes.add(x), remove: x => classes.delete(x), contains: x => classes.has(x)}});
    }
    return nodes.get(selector);
  }
  const context = vm.createContext({fetch, navigator: {language: 'en'},
    localStorage: {getItem() {return null}},
    document: {querySelector: node, querySelectorAll: s => s.split(',').map(x => node(x.trim())),
      addEventListener() {}, activeElement: node('input'), documentElement: node('html')},
    setTimeout(fn) {const id = ++nextTimer; timers.set(id, fn); return id},
    clearTimeout(id) {timers.delete(id)}});
  vm.runInContext(script, context);
  vm.runInContext(`data = ${JSON.stringify(initial)}; loaded = true;`, context);
  node('#modalBg').classList.add('show');
  return {context, node, data: () => JSON.parse(vm.runInContext('JSON.stringify(data)', context)),
    fireTimers() {const pending = [...timers.values()]; timers.clear(); return Promise.all(pending.map(fn => fn()))}};
}

test('HTTP failure keeps confirmation open, preserves edits and supports retry', async () => {
  let ok = false;
  const p = page(async () => ({ok, status: ok ? 200 : 500}));
  await p.context.finish();
  assert.equal(p.node('#done').classList.contains('show'), false);
  assert.deepEqual(p.data(), initial);
  assert.equal(p.node('#mOk').disabled, false);
  assert.match(p.node('#saved').textContent, /could not save/i);
  ok = true;
  await p.context.finish();
  assert.equal(p.node('#done').classList.contains('show'), true);
  assert.equal(p.data().items[0].status, 'confirmed');
  assert.equal(p.data().items[1].status, 'deleted');
  assert.equal('_touched' in p.data().items[0], false);
  assert.equal('_dropped' in p.data().items[1], false);
});

test('network failure is retryable without losing review decisions', async () => {
  const p = page(async () => {throw new TypeError('connection lost')});
  await p.context.finish();
  assert.deepEqual(p.data(), initial);
  assert.equal(p.node('#done').classList.contains('show'), false);
  assert.equal(p.node('#mOk').disabled, false);
});

test('confirmation cancels pending autosave and sends the latest full snapshot', async () => {
  const calls = [];
  const p = page(async (url, options) => {calls.push([url, JSON.parse(options.body)]); return {ok: true}});
  p.context.save();
  await p.context.finish();
  await p.fireTimers();
  assert.deepEqual(calls.map(x => x[0]), ['/api/confirm']);
  assert.equal(calls[0][1].items[0].title, 'Edited');
  assert.equal(calls[0][1].items[0].status, 'confirmed');
});

test('confirmation waits for in-flight autosave even when that save fails', async () => {
  const pending = deferred(), calls = [];
  const p = page((url) => {calls.push(url); return url === '/api/items' ? pending.promise : Promise.resolve({ok: true})});
  p.context.save();
  const saving = p.fireTimers();
  await flush();
  const finishing = p.context.finish();
  await flush();
  assert.deepEqual(calls, ['/api/items']);
  pending.resolve({ok: false, status: 500});
  await saving;
  await finishing;
  assert.deepEqual(calls, ['/api/items', '/api/confirm']);
  assert.equal(p.node('#done').classList.contains('show'), true);
});

test('duplicate confirmation is ignored and editing is frozen while saving', async () => {
  const pending = deferred();
  let count = 0;
  const p = page(() => {count++; return pending.promise});
  const first = p.context.finish();
  const second = p.context.finish();
  await flush();
  assert.equal(count, 1);
  assert.equal(p.node('#mOk').disabled, true);
  assert.equal(p.node('#focusView').inert, true);
  assert.equal(p.node('.top').inert, true);
  assert.equal(p.node('#toast').inert, true);
  p.context.closeModal();
  assert.equal(p.node('#modalBg').classList.contains('show'), true);
  pending.resolve({ok: false, status: 500});
  await Promise.all([first, second]);
  assert.equal(p.node('#focusView').inert, false);
});

test('undo cannot change the snapshot while confirmation is pending', async () => {
  const pending = deferred();
  const p = page(() => pending.promise);
  vm.runInContext('undo.push(JSON.stringify({items: [], cur: 0})); render = () => {}; toast = () => {};', p.context);
  const finishing = p.context.finish();
  await flush();
  p.context.doUndo();
  assert.deepEqual(p.data(), initial);
  assert.equal(vm.runInContext('undo.length', p.context), 1);
  pending.resolve({ok: false, status: 500});
  await finishing;
  p.context.doUndo();
  assert.deepEqual(p.data().items, []);
});

test('HTTP autosave failure is visible and does not poison the next save', async () => {
  let ok = false;
  const p = page(async () => ({ok, status: ok ? 200 : 500}));
  p.context.save();
  await p.fireTimers();
  assert.match(p.node('#saved').textContent, /could not save/i);
  ok = true;
  p.context.save();
  await p.fireTimers();
  assert.equal(p.node('#saved').textContent, 'Saved');
});

test('autosaves are serial and an older response cannot mark a newer edit saved', async () => {
  const first = deferred(), second = deferred(), calls = [];
  const p = page((url, options) => {calls.push(JSON.parse(options.body)); return calls.length === 1 ? first.promise : second.promise});
  p.context.save();
  const firstSave = p.fireTimers();
  await flush();
  vm.runInContext('data.items[0].title = "Newer edit";', p.context);
  p.context.save();
  const secondSave = p.fireTimers();
  await flush();
  assert.equal(calls.length, 1);
  first.resolve({ok: true});
  await firstSave;
  await flush();
  assert.equal(p.node('#saved').textContent, 'Saving…');
  assert.equal(calls[1].items[0].title, 'Newer edit');
  second.resolve({ok: true});
  await secondSave;
  assert.equal(p.node('#saved').textContent, 'Saved');
});
