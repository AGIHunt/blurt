// @vitest-environment jsdom
import { act, createElement } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { afterEach, expect, it, vi } from 'vitest';
import { api, type ModelApiStatus } from '../api';
import { setLang } from '../i18n';
import { ExternalModelAPISection } from './ExternalModelAPISection';

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
let root: Root;
const off: ModelApiStatus = { running: false, scope: 'local', base_url: '', models: [] };
const on: ModelApiStatus = { running: true, scope: 'local', base_url: 'http://127.0.0.1:11435/v1',
  models: [{ id: 'chat-a', capability: 'chat' }, { id: 'ocr-b', capability: 'ocr' }] };

async function mount() {
  setLang('en');
  root = createRoot(document.body.appendChild(document.createElement('div')));
  await act(async () => root.render(createElement(ExternalModelAPISection)));
}
afterEach(() => {
  act(() => root.unmount());
  document.body.replaceChildren();
  vi.restoreAllMocks();
});

async function click(label: string, parent: ParentNode = document) {
  const el = [...parent.querySelectorAll<HTMLElement>('button, [role="menuitemcheckbox"]')].find((b) => b.textContent?.trim() === label);
  expect(el, label).toBeTruthy();
  await act(async () => el!.click());
}
function row(label: string) {
  return [...document.querySelectorAll('.st-row')].find((el) => el.querySelector('.st-row-title')?.textContent === label)!;
}

it('reads credentials only when copying a key or a configuration for the selected model', async () => {
  const control = vi.spyOn(api, 'modelApi').mockResolvedValueOnce(off).mockResolvedValue(on);
  const config = vi.spyOn(api, 'modelApiConfig').mockResolvedValue({ ...on, api_key: 'local-test-key',
    python_examples: { 'chat-a': 'chat example', 'ocr-b': 'OCR example with local-test-key' } });
  const clipboard = vi.spyOn(api, 'copyText').mockResolvedValue();
  await mount();
  expect(control.mock.calls).toEqual([['status', undefined]]);
  await click('Start service');
  expect(control).toHaveBeenLastCalledWith('start', 'local');
  await click('chat-a');
  await click('ocr-b');
  await click('Copy', row('Model ID'));
  expect(clipboard).toHaveBeenLastCalledWith('ocr-b');
  await click('Copy', row('Base URL'));
  expect(clipboard).toHaveBeenLastCalledWith(on.base_url);
  expect(config).not.toHaveBeenCalled();

  await click('Copy', row('API key'));
  expect(clipboard).toHaveBeenLastCalledWith('local-test-key');
  await click('Copy JSON');
  expect(JSON.parse(clipboard.mock.lastCall![0])).toEqual({ base_url: on.base_url, api_key: 'local-test-key', model: 'ocr-b' });
  await click('Copy Python example');
  expect(clipboard).toHaveBeenLastCalledWith('OCR example with local-test-key');
  expect(config).toHaveBeenCalledTimes(3);
  expect(document.body.textContent).not.toContain('local-test-key');

  config.mockResolvedValueOnce({ ...on, models: [], api_key: 'local-test-key', python_examples: {} });
  await click('Copy JSON');
  expect(document.body.textContent).toContain('Refresh and try again');
  expect(clipboard).toHaveBeenCalledTimes(5);
});

it('requires choosing LAN before starting and returns to local after stopping', async () => {
  const control = vi.spyOn(api, 'modelApi')
    .mockResolvedValueOnce(off)
    .mockResolvedValueOnce({ ...on, scope: 'lan', base_url: 'http://192.0.2.1:11435/v1', models: [] })
    .mockResolvedValueOnce(off);
  await mount();
  expect(document.body.textContent).toContain('No supported local models');
  await click('This computer only');
  await click('Trusted local network');
  expect(document.body.textContent).toContain('unencrypted HTTP');
  expect(control).toHaveBeenCalledTimes(1);
  await click('Start service');
  expect(control).toHaveBeenLastCalledWith('start', 'lan');
  expect(document.body.textContent).toContain('http://192.0.2.1:11435/v1');
  expect(document.body.textContent).not.toContain('Copy JSON');
  await click('Stop service');
  expect(control).toHaveBeenLastCalledWith('stop', undefined);
  expect(document.body.textContent).toContain('This computer only');
  expect(document.body.textContent).not.toContain('192.0.2.1');
});

it('recovers from a failed status read and reloads changes on window focus', async () => {
  vi.spyOn(api, 'modelApi').mockRejectedValueOnce(new Error('test: runner unavailable')).mockResolvedValueOnce(on).mockResolvedValueOnce(off);
  await mount();
  expect(document.body.textContent).toContain('test: runner unavailable');
  expect(document.body.textContent).not.toContain('Start service');
  await click('Refresh');
  expect(document.body.textContent).toContain('Stop service');
  await act(async () => { window.dispatchEvent(new Event('focus')); });
  expect(document.body.textContent).toContain('Start service');
  expect(document.body.textContent).not.toContain('Stop service');
});

it('prepares only the explicitly selected runtime, whether the service is stopped or running', async () => {
  vi.spyOn(api, 'modelApi').mockResolvedValueOnce({ ...off, models: on.models }).mockResolvedValue(on);
  const prepare = vi.spyOn(api, 'modelApiPrepare').mockResolvedValue(on);
  const config = vi.spyOn(api, 'modelApiConfig');
  await mount();
  expect(document.body.textContent).toContain('may download Python packages');
  await click('chat-a');
  await click('ocr-b');
  expect(prepare).not.toHaveBeenCalled();
  await click('Prepare runtime');
  expect(prepare).toHaveBeenLastCalledWith('ocr-b');
  expect(document.body.textContent).toContain('The runtime for ocr-b is ready.');
  await click('Start service');
  expect(prepare).toHaveBeenCalledTimes(1);
  await click('ocr-b');
  await click('chat-a');
  await click('Prepare runtime');
  expect(prepare).toHaveBeenLastCalledWith('chat-a');
  expect(config).not.toHaveBeenCalled();
});

it('copies the address, JSON configuration and SDK example for the chosen chat protocol', async () => {
  const status = { ...on, messages_base_url: 'http://127.0.0.1:11435' };
  vi.spyOn(api, 'modelApi').mockResolvedValue(status);
  vi.spyOn(api, 'modelApiConfig').mockResolvedValue({ ...status, api_key: 'test-key',
    python_examples: { 'chat-a': 'OpenAI()' }, messages_python_examples: { 'chat-a': 'Anthropic()' } });
  const clipboard = vi.spyOn(api, 'copyText').mockResolvedValue();
  await mount();
  await click('OpenAI Chat Completions');
  await click('Messages-compatible API');
  await click('Copy', row('Base URL'));
  expect(clipboard).toHaveBeenLastCalledWith(status.messages_base_url);
  await click('Copy JSON');
  expect(JSON.parse(clipboard.mock.lastCall![0])).toEqual({ base_url: status.messages_base_url, api_key: 'test-key', model: 'chat-a' });
  await click('Copy Python example');
  expect(clipboard).toHaveBeenLastCalledWith('Anthropic()');
  await click('Messages-compatible API');
  await click('OpenAI Chat Completions');
  await click('Copy', row('Base URL'));
  expect(clipboard).toHaveBeenLastCalledWith(status.base_url);
  await click('Copy Python example');
  expect(clipboard).toHaveBeenLastCalledWith('OpenAI()');
});
