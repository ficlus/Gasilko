import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const read = locale => JSON.parse(readFileSync(new URL('../messages/' + locale + '.json', import.meta.url), 'utf8'));
test('both supported languages provide every nonempty message', () => {
  const sl = read('sl'); const de = read('de');
  assert.deepEqual(Object.keys(sl).sort(), Object.keys(de).sort());
  for (const messages of [sl,de]) for (const value of Object.values(messages)) assert.ok(typeof value === 'string' && value.trim().length > 0);
});
