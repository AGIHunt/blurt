// Settings → Models → the cloud services (docs: the 2026-11-16 "cloud services from the top" round): what Add Cloud
// Model offers, which jobs its 用于 boxes have, what a connected service's row says uses it, and when it offers
// Use for Dictation.
import { describe, expect, it } from 'vitest';
import { addSheetServices, listIn, offersDictation, sheetJobs, usesOf } from './settings/cloudPresets';

describe('Add Cloud Model lists every service', () => {
  it('the curated ones not added yet, then every other preset, the user’s own last and always', () => {
    const { curated, others } = addSheetServices([], true);
    expect(curated).toEqual(['deepseek', 'dashscope', 'volcengine-speech']);
    expect(others).toEqual(['volcengine', 'moonshot', 'zhipu', 'minimax', 'xiaomi', 'openai', 'anthropic', 'gemini', 'openrouter', 'custom-openai', 'custom-anthropic']);
  });

  it('a service added is gone from the list; the user’s own address never is', () => {
    const { curated, others } = addSheetServices(['deepseek', 'moonshot', 'custom-openai'], true);
    expect(curated).toEqual(['dashscope', 'volcengine-speech']);
    expect(others).not.toContain('moonshot');
    expect(others.slice(-2)).toEqual(['custom-openai', 'custom-anthropic']);
  });

  it('Volcengine Speech only where it is offered; no other speech-only service ever', () => {
    const { curated, others } = addSheetServices([], false);
    expect(curated).toEqual(['deepseek', 'dashscope']);
    expect(others).not.toContain('volcengine-speech');
  });

  it('the 用于 boxes: the jobs this build has, Copy Text unchecked', () => {
    expect(sheetJobs({ dictation: true, screenText: true })).toEqual([{ job: 'polish', on: true }, { job: 'translate', on: true }, { job: 'vision', on: false }]);
    expect(sheetJobs({ dictation: true, screenText: false }).map((j) => j.job)).toEqual(['polish', 'translate']);
    expect(sheetJobs({ dictation: false, screenText: false })).toEqual([]);
  });
});

describe('a connected service says what uses it', () => {
  const ds = { id: 'dashscope', preset: 'dashscope' };
  const jobs = ['polish', 'translate', 'vision'] as const;
  it('the text jobs routed to it; translate follows polish', () => {
    expect(usesOf(ds, { polish: { service: 'dashscope', model: 'm' }, translate: null, vision: { service: 'deepseek', model: 'x' } }, [...jobs], null)).toEqual(['polish', 'translate']);
    expect(usesOf(ds, { polish: { service: 'deepseek', model: 'm' } }, [...jobs], null)).toEqual([]);
  });

  it('dictation first when it recognises there', () => {
    const d = { selected: 'qwen3-asr-flash', selected_cloud: true };
    expect(usesOf(ds, { vision: { service: 'dashscope', model: 'q' } }, [...jobs], d)).toEqual(['dictation', 'vision']);
    expect(usesOf({ id: 'volcengine-speech', preset: 'volcengine-speech' }, {}, [...jobs], { selected: 'volcengine-seedasr', selected_cloud: true })).toEqual(['dictation']);
    // a local model by the same name never counts
    expect(usesOf(ds, {}, [...jobs], { selected: 'qwen3-asr-flash', selected_cloud: false })).toEqual([]);
  });

  it('only jobs this build has', () => {
    expect(usesOf(ds, { vision: { service: 'dashscope', model: 'q' } }, ['polish', 'translate'], null)).toEqual([]);
  });

  it('the list reads as a sentence in each language', () => {
    expect(listIn(['听写', '听写润色', '翻译'], 'zh-Hans')).toBe('听写、听写润色、翻译');
    expect(listIn(['Dictation', 'Translate'], 'en')).toBe('Dictation, Translate');
  });
});

describe('Use for Dictation', () => {
  const local = { selected: 'sensevoice-small', selected_cloud: false, cloud_allowed: true };
  it('a speech service with a key, dictation built, cloud recognition allowed, not already on it', () => {
    expect(offersDictation('dashscope', true, true, local)).toBe(true);
    expect(offersDictation('volcengine-speech', true, true, local)).toBe(true);
    expect(offersDictation('openai', true, true, local)).toBe(false);
    expect(offersDictation('deepseek', true, true, local)).toBe(false);
    expect(offersDictation('dashscope', false, true, local)).toBe(false);
    expect(offersDictation('dashscope', true, false, local)).toBe(false);
    expect(offersDictation('dashscope', true, true, { ...local, cloud_allowed: false })).toBe(false);
    expect(offersDictation('dashscope', true, true, { selected: 'qwen3-asr-flash', selected_cloud: true })).toBe(false);
    expect(offersDictation('dashscope', true, true, null)).toBe(false);
  });
});
