// Settings → Models → a job's Advanced → Custom Model…: the presets' addresses (the Mac's CloudPreset.all and cloud.rs
// PRESETS), a pasted key naming its service, the region a new service starts on.
import { describe, expect, it } from 'vitest';
import { detectKey, endpointOf, hostOf, isCustom, isRegional, systemRegion, TEXT_PRESETS, textPreset } from './settings/cloudPresets';

describe('custom model presets', () => {
  it('a preset with two addresses keeps a region; the user’s own has none', () => {
    const mm = textPreset('minimax')!;
    expect(isRegional(mm)).toBe(true);
    expect(endpointOf(mm, 'china')?.base).toBe('https://api.minimax.cn/v1');
    expect(endpointOf(mm, 'global')?.base).toBe('https://api.minimax.io/v1');
    expect(endpointOf(textPreset('deepseek')!, 'global')?.base).toBe('https://api.deepseek.com');
    expect(isCustom(textPreset('custom-anthropic')!)).toBe(true);
    expect(textPreset('custom-anthropic')!.protocol).toBe('anthropic');
    expect(textPreset('volcengine-speech')).toBeUndefined();
    // the user's own last, as the Mac lists them
    expect(TEXT_PRESETS.slice(-2).map((p) => p.id)).toEqual(['custom-openai', 'custom-anthropic']);
  });

  it('a key names its service only by a start no other service uses', () => {
    expect(detectKey('sk-cp-abc123')).toBe('minimax'); // MiniMax Token Plan
    expect(detectKey(' sk-ant-api03-x\n')).toBe('anthropic');
    expect(detectKey('sk-or-v1-x')).toBe('openrouter');
    expect(detectKey('AIzaSyx')).toBe('gemini');
    expect(detectKey('sk-proj-x')).toBe('openai');
    expect(detectKey('sk-0123456789abcdef')).toBeNull();
    expect(detectKey('')).toBeNull();
  });

  it('the region follows the system’s language and country', () => {
    expect(systemRegion(['zh-CN'])).toBe('china');
    expect(systemRegion(['zh-Hans'])).toBe('china');
    expect(systemRegion(['zh-TW', 'en-US'])).toBe('global');
    expect(systemRegion(['en-US'])).toBe('global');
    expect(systemRegion([])).toBe('global');
  });

  it('a service of the user’s own is called by its host', () => {
    expect(hostOf('https://opencode.ai/zen/go/v1')).toBe('opencode.ai');
    expect(hostOf('http://localhost:11434/v1')).toBe('localhost:11434');
    expect(hostOf('not a url')).toBe('not a url');
  });
});
