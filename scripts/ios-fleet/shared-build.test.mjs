import test from 'node:test';
import assert from 'node:assert/strict';
import {nextSharedBuild as next} from './shared-build.mjs';
// The merge stamp is set explicitly, so every case is deterministic.
const STAMP = '202610290930';
const input = {iosBuilds: [], macBuilds: [], complete: true, mergeStamp: STAMP};
test('a fresh app plans the merge stamp itself', () => {
  assert.deepEqual(next(input), {build: STAMP});
});
test('an existing build below the stamp plans the stamp', () => {
  assert.deepEqual(next({...input, iosBuilds: ['1000']}), {build: STAMP});
  assert.deepEqual(next({...input, macBuilds: ['2394']}), {build: STAMP});
  assert.deepEqual(next({...input, iosBuilds: ['1100'], macBuilds: ['1200']}), {build: STAMP});
});
test('an existing build at the stamp goes one up, so a rebuild still rises', () => {
  assert.deepEqual(next({...input, iosBuilds: [STAMP]}), {build: '202610290931'});
  assert.deepEqual(next({...input, macBuilds: [STAMP]}), {build: '202610290931'});
});
test('an existing build above the stamp goes one up', () => {
  assert.deepEqual(next({...input, iosBuilds: ['209912312359']}), {build: '209912312360'});
  assert.deepEqual(next({...input, macBuilds: ['209912312359']}), {build: '209912312360'});
});
test('iOS timestamp builds count now', () => {
  assert.deepEqual(
    next({...input, iosBuilds: ['202610190645', '202610180127']}),
    {build: STAMP}
  );
  assert.deepEqual(
    next({...input, iosBuilds: ['202610190645', '2394']}),
    {build: STAMP}
  );
  assert.deepEqual(
    next({...input, iosBuilds: ['202610190645'], mergeStamp: '202610190645'}),
    {build: '202610190646'}
  );
  assert.deepEqual(
    next({...input, iosBuilds: ['202610190645'], mergeStamp: '202501010000'}),
    {build: '202610190646'}
  );
});
test('a mac-only higher build wins', () => {
  assert.deepEqual(
    next({...input, iosBuilds: ['1100'], macBuilds: ['202611010800']}),
    {build: '202611010801'}
  );
});
test('the counter spans an iOS build, a macOS build and a floor', () => {
  assert.deepEqual(
    next({...input, iosBuilds: ['1100'], macBuilds: ['1200'], extraFloors: [1500]}),
    {build: STAMP}
  );
  assert.deepEqual(
    next({...input, iosBuilds: ['1100'], macBuilds: ['1200'], extraFloors: [202611010800]}),
    {build: '202611010801'}
  );
  assert.deepEqual(
    next({...input, mergeStamp: '202501010000', iosBuilds: ['1100'], macBuilds: ['1200'], extraFloors: [1500]}),
    {build: '202501010000'}
  );
});
test('dotted builds count by their first numeric component', () => {
  assert.deepEqual(next({...input, iosBuilds: ['0.1.3', '1.1.2']}), {build: STAMP});
  assert.deepEqual(next({...input, macBuilds: ['0.1.3']}), {build: STAMP});
  assert.deepEqual(
    next({...input, iosBuilds: [`${STAMP}.1`]}),
    {build: '202610290931'}
  );
});
test('paired apps join as concatenated per-platform lists', () => {
  assert.deepEqual(
    next({...input, iosBuilds: ['1100', '1400'], macBuilds: ['1200', '1300']}),
    {build: STAMP}
  );
  assert.deepEqual(
    next({...input, mergeStamp: '202501010000', iosBuilds: ['1100', '1400'], macBuilds: ['1200', '1300']}),
    {build: '202501010000'}
  );
  assert.deepEqual(
    next({...input, iosBuilds: ['1100', '202611010800'], macBuilds: ['1200', '1300']}),
    {build: '202611010801'}
  );
});
test('extra floors accept plain integers and 12-digit strings', () => {
  assert.deepEqual(next({...input, extraFloors: [986]}), {build: STAMP});
  assert.deepEqual(next({...input, extraFloors: ['1500']}), {build: STAMP});
  assert.deepEqual(next({...input, extraFloors: ['202611010800']}), {build: '202611010801'});
});
test('a plan above 12 digits throws instead of shipping past the gate', () => {
  assert.throws(() => next({...input, extraFloors: ['2026102909300']}), /planned build exceeds 12 digits/);
  assert.throws(() => next({...input, extraFloors: ['202611010800000001']}), /planned build exceeds 12 digits/);
  assert.throws(() => next({...input, iosBuilds: ['202611010800000001']}), /planned build exceeds 12 digits/);
  assert.throws(() => next({...input, macBuilds: ['999999999999']}), /planned build exceeds 12 digits/);
});
test('the build is a plain integer with no leading zeros', () => {
  const {build} = next({...input, iosBuilds: ['0236']});
  assert.match(build, /^[1-9][0-9]*$/);
});
test('malformed inventory throws before computing', () => {
  for (const bad of [null, 'NaN', '1.2.3.4', 42, '', ' 1000', 'v1']) {
    assert.throws(() => next({...input, iosBuilds: [bad]}), /malformed build inventory/);
    assert.throws(() => next({...input, macBuilds: [bad]}), /malformed build inventory/);
  }
  for (const bad of [-1, 1.5, NaN, null, '', 'abc', '1.5', '-3', ' 1500', '1500 ']) {
    assert.throws(() => next({...input, extraFloors: [bad]}), /malformed build inventory/);
  }
  assert.throws(() => next({...input, extraFloors: '1500'}), /malformed build inventory/);
  // A malformed entry is reported even when a higher build would also apply.
  assert.throws(() => next({...input, iosBuilds: ['209912312359', 'NaN']}), /malformed build inventory/);
});
test('a bad merge stamp throws', () => {
  for (const bad of [undefined, null, 202610290930, '', '20261029093', '2026102909301', '022610290930', '20261029093a', ' 202610290930']) {
    assert.throws(() => next({...input, mergeStamp: bad}), /malformed merge stamp/);
  }
  const {mergeStamp: _drop, ...missing} = input;
  assert.throws(() => next(missing), /malformed merge stamp/);
});
test('incomplete inventory refuses', () => {
  assert.throws(() => next({...input, complete: false}), /complete build inventory required/);
  assert.throws(() => next({...input, complete: undefined}), /complete build inventory required/);
  assert.throws(() => next({iosBuilds: [], complete: true, mergeStamp: STAMP}), /complete build inventory required/);
  assert.throws(() => next({macBuilds: [], complete: true, mergeStamp: STAMP}), /complete build inventory required/);
  assert.throws(() => next({iosBuilds: '1000', macBuilds: [], complete: true, mergeStamp: STAMP}), /complete build inventory required/);
});
