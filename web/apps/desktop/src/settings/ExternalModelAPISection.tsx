import { useCallback, useEffect, useRef, useState } from 'react';
import { api, type ModelApiScope, type ModelApiStatus } from '../api';
import { Group, Line, Popup, S } from './kit';

type Action = 'status' | 'start' | 'stop';

// When the user leaves Models during Start or Stop, the next mount reads status after that command finishes.
let pendingControl: Promise<void> = Promise.resolve();
// Keep an explicit download in view if the user returns here while it is still running.
let preparation: { model: string; result: Promise<string> } | null = null;

export function ExternalModelAPISection() {
  const [status, setStatus] = useState<ModelApiStatus | null>(null);
  const [format, setFormat] = useState('openai');
  const [scope, setScope] = useState<ModelApiScope>('local');
  const [selected, setSelected] = useState('');
  const [message, setMessage] = useState('');
  const [busy, setBusy] = useState(true);
  const locked = useRef(false);
  const [job, setJob] = useState(preparation);
  const [runtimeMessage, setRuntimeMessage] = useState('');

  useEffect(() => {
    if (!job) return;
    let active = true;
    job.result.then((message) => {
      if (active) { setRuntimeMessage(message); setJob(null); }
    });
    return () => { active = false; };
  }, [job]);
  const prepare = (model: string) => {
    if (preparation) return;
    const result = api.modelApiPrepare(model).then(() => S('models.api.prepared', model), (e) => String(e));
    preparation = { model, result };
    setJob(preparation);
    result.then(() => { preparation = null; });
  };

  const control = useCallback(async (action: Action, access?: ModelApiScope) => {
    if (locked.current) return;
    locked.current = true;
    setBusy(true);
    setMessage('');
    try {
      const read = pendingControl.then(() => api.modelApi(action, access));
      pendingControl = read.then(() => {}, () => {});
      const next = await read;
      setStatus(next);
      setSelected((id) => next.models.some((m) => m.id === id) ? id : next.models.find((m) => m.capability === 'chat')?.id ?? next.models[0]?.id ?? '');
      if (next.running || action === 'stop') setScope('local');
    } catch (e) {
      setStatus(null);
      setMessage(String(e));
    } finally {
      locked.current = false;
      setBusy(false);
    }
  }, []);
  useEffect(() => {
    const refresh = () => { void control('status'); };
    refresh();
    window.addEventListener('focus', refresh);
    return () => window.removeEventListener('focus', refresh);
  }, [control]);

  const messagesFormat = (v: ModelApiStatus) => format === 'messages' && !!v.messages_base_url && !v.needs_restart
    && v.models.find((m) => m.id === selected)?.capability === 'chat';
  const baseUrl = (v: ModelApiStatus) => (messagesFormat(v) ? v.messages_base_url : v.base_url) || v.base_url;
  const copy = async (field: 'base' | 'model' | 'key' | 'json' | 'python') => {
    if (locked.current || !status) return;
    locked.current = true;
    setBusy(true);
    setMessage('');
    try {
      let text: string;
      if (field === 'base') text = baseUrl(status);
      else if (field === 'model') text = selected;
      else {
        const current = await api.modelApiConfig();
        if (!current.running || !current.base_url || !current.api_key ||
            (field !== 'key' && !current.models.some((m) => m.id === selected))) {
          setMessage(S('models.api.changed'));
          return;
        }
        if (field === 'key') text = current.api_key;
        else if (field === 'json') text = JSON.stringify({ base_url: baseUrl(current), api_key: current.api_key, model: selected }, null, 2);
        else {
          text = (messagesFormat(current) ? current.messages_python_examples : current.python_examples)?.[selected] || '';
          if (!text) { setMessage(S('models.api.changed')); return; }
        }
      }
      await api.copyText(text);
      setMessage(S('models.api.copied'));
    } catch (e) {
      setMessage(String(e));
    } finally {
      locked.current = false;
      setBusy(false);
    }
  };

  const model = status?.models.find((m) => m.id === selected);
  const actualScope = status?.running ? status.scope : scope;
  const capability = model && (['chat', 'transcription', 'ocr'].includes(model.capability) ? S(`models.api.${model.capability}`) : model.capability);
  return (
    <Group id="speech.api" footer={S('models.api.detail')}>
      <Line title={S('models.api.service')} detail={S(busy ? 'models.api.working' : !status ? 'models.api.unknown' : status.needs_restart ? 'models.api.restart' : status.running ? 'models.api.running' : 'models.api.stopped')}>
        <button disabled={busy} onClick={() => control('status')}>{S('models.api.refresh')}</button>
        {status && <button disabled={busy} onClick={() => status.running ? control('stop') : control('start', scope)}>{S(status.running ? 'models.api.stop' : 'models.api.start')}</button>}
      </Line>
      {status && <>
        <Line title={S('models.api.access')} detail={actualScope === 'lan' ? S('models.api.lan_detail') : undefined}>
          {status.running ? S(`models.api.${status.scope}`) : <Popup label={S('models.api.access')} disabled={busy} value={scope} onChange={setScope}
            choices={[['local', S('models.api.local')], ['lan', S('models.api.lan')]]} />}
        </Line>
        <Line title={S('models.api.model')} detail={capability ?? S('models.api.empty')}>
          {model && <>
            <Popup label={S('models.api.model')} disabled={busy} value={selected} onChange={setSelected} choices={status.models.map((m) => [m.id, m.id])} />
            <button disabled={busy} onClick={() => copy('model')}>{S('models.api.copy')}</button>
          </>}
        </Line>
        {status.running && <>
          {model?.capability === 'chat' && !status.needs_restart && <Line title={S('models.api.format')}>
            <Popup label={S('models.api.format')} disabled={busy} value={format} onChange={setFormat}
              choices={[['openai', 'OpenAI Chat Completions'], ['messages', 'Messages-compatible API']]} />
          </Line>}
          <Line title={S('models.api.base')} detail={baseUrl(status)}>
            <button disabled={busy} onClick={() => copy('base')}>{S('models.api.copy')}</button>
          </Line>
          <Line title={S('models.sheet.key')}>
            <button disabled={busy} onClick={() => copy('key')}>{S('models.api.copy')}</button>
          </Line>
        </>}
        {model && <Line title={S('models.api.runtime')} detail={job ? S('models.api.preparing', job.model) : runtimeMessage || S('models.api.runtime_detail')}>
          <button disabled={busy || !!job} onClick={() => prepare(model.id)}>{S('models.api.prepare')}</button>
        </Line>}
        {status.running && model && <Line title={S('models.api.config')}>
          <button disabled={busy} onClick={() => copy('json')}>{S('models.api.copy_json')}</button>
          <button disabled={busy} onClick={() => copy('python')}>{S('models.api.copy_python')}</button>
        </Line>}
      </>}
      {message && <p className="st-detail" role="status">{message}</p>}
    </Group>
  );
}
