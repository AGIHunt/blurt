// The cloud services a Custom Model can be on (the Mac's CloudPreset.all, CloudServices.swift; cloud.rs PRESETS keeps
// the same table for the requests): each one's addresses per region, where its key is made, the model ids its docs
// name (suggestions for the Model ID field), and the key starts only that service uses. custom-openai /
// custom-anthropic are the user's own address. Volcengine Speech isn't here: it has no text models.

export type Region = 'china' | 'global';
export interface Endpoint {
  region: Region | null;
  base: string;
  /** where a key is made */
  page: string;
  /** model ids the docs name, newest first (only for a service whose list can't be read) */
  known?: string[];
}
export interface TextPreset {
  id: string;
  protocol: 'openai' | 'anthropic';
  endpoints: Endpoint[];
  /** a pasted key that starts like this is this service's (only starts no other service uses) */
  keyPrefixes: string[];
}

const MINIMAX = ['MiniMax-M3.1-Flash', 'MiniMax-M3'];
const ZHIPU = ['glm-5.3', 'glm-5.3-flash', 'glm-5.3-flashx', 'glm-4.7-flashx', 'glm-4.7-flash', 'glm-4.6v', 'glm-4.6v-flashx', 'glm-4.6v-flash'];

export const TEXT_PRESETS: TextPreset[] = [
  { id: 'deepseek', protocol: 'openai', keyPrefixes: [], endpoints: [{ region: null, base: 'https://api.deepseek.com', page: 'https://platform.deepseek.com/api_keys' }] },
  { id: 'dashscope', protocol: 'openai', keyPrefixes: [], endpoints: [
    { region: 'china', base: 'https://dashscope.aliyuncs.com/compatible-mode/v1', page: 'https://bailian.console.aliyun.com/?tab=model#/api-key' },
    { region: 'global', base: 'https://dashscope-intl.aliyuncs.com/compatible-mode/v1', page: 'https://modelstudio.console.alibabacloud.com/?tab=model#/api-key' },
  ] },
  { id: 'volcengine', protocol: 'openai', keyPrefixes: [], endpoints: [
    { region: 'china', base: 'https://ark.cn-beijing.volces.com/api/v3', page: 'https://console.volcengine.com/ark/region:ark+cn-beijing/apiKey',
      known: ['doubao-seed-2-1-pro-260915', 'doubao-seed-2-1-lite-260915', 'doubao-seed-2-1-turbo-260628', 'doubao-seed-2-0-lite-260428', 'doubao-seed-2-0-mini-260428'] },
    { region: 'global', base: 'https://ark.ap-southeast.bytepluses.com/api/v3', page: 'https://console.byteplus.com/ark/region:ark+ap-southeast-1/apiKey',
      known: ['dola-seed-2-1-turbo-260628', 'seed-2-0-pro-260328'] },
  ] },
  { id: 'moonshot', protocol: 'openai', keyPrefixes: [], endpoints: [
    { region: 'china', base: 'https://api.moonshot.cn/v1', page: 'https://platform.kimi.com/' },
    { region: 'global', base: 'https://api.moonshot.ai/v1', page: 'https://platform.kimi.ai/' },
  ] },
  { id: 'zhipu', protocol: 'openai', keyPrefixes: [], endpoints: [
    { region: 'china', base: 'https://open.bigmodel.cn/api/paas/v4', page: 'https://open.bigmodel.cn/usercenter/proj-mgmt/apikeys', known: ZHIPU },
    { region: 'global', base: 'https://api.z.ai/api/paas/v4', page: 'https://z.ai/manage-apikey/apikey-list', known: ZHIPU },
  ] },
  // sk-cp-: a Token Plan (subscription) key, on the same addresses as a pay-as-you-go one
  { id: 'minimax', protocol: 'openai', keyPrefixes: ['sk-cp-'], endpoints: [
    { region: 'china', base: 'https://api.minimax.cn/v1', page: 'https://platform.minimax.cn/', known: MINIMAX },
    { region: 'global', base: 'https://api.minimax.io/v1', page: 'https://platform.minimax.io/', known: MINIMAX },
  ] },
  { id: 'xiaomi', protocol: 'openai', keyPrefixes: [], endpoints: [
    { region: null, base: 'https://api.xiaomimimo.com/v1', page: 'https://platform.xiaomimimo.com/', known: ['mimo-v2.6-flash', 'mimo-v2.6-pro', 'mimo-v2.5', 'mimo-v2.5-pro'] },
  ] },
  { id: 'openai', protocol: 'openai', keyPrefixes: ['sk-proj-', 'sk-svcacct-', 'sk-admin-'], endpoints: [{ region: null, base: 'https://api.openai.com/v1', page: 'https://platform.openai.com/api-keys' }] },
  { id: 'anthropic', protocol: 'anthropic', keyPrefixes: ['sk-ant-'], endpoints: [{ region: null, base: 'https://api.anthropic.com', page: 'https://platform.claude.com/settings/keys' }] },
  { id: 'gemini', protocol: 'openai', keyPrefixes: ['AIza'], endpoints: [{ region: null, base: 'https://generativelanguage.googleapis.com/v1beta/openai', page: 'https://aistudio.google.com/apikey' }] },
  { id: 'openrouter', protocol: 'openai', keyPrefixes: ['sk-or-'], endpoints: [{ region: null, base: 'https://openrouter.ai/api/v1', page: 'https://openrouter.ai/keys' }] },
  { id: 'custom-openai', protocol: 'openai', keyPrefixes: [], endpoints: [] },
  { id: 'custom-anthropic', protocol: 'anthropic', keyPrefixes: [], endpoints: [] },
];

export const textPreset = (id: string) => TEXT_PRESETS.find((p) => p.id === id);
/** the user's own address (no preset address) */
export const isCustom = (p: TextPreset) => p.endpoints.length === 0;
/** two addresses: the service keeps its region */
export const isRegional = (p: TextPreset) => p.endpoints.length > 1;
/** a preset's address for a region: that region's, else its first */
export const endpointOf = (p: TextPreset, region: Region | null): Endpoint | undefined =>
  p.endpoints.find((e) => region && e.region === region) ?? p.endpoints[0];

/** The service a pasted key belongs to, when its start says so (sk-cp-, sk-ant-, sk-or-, AIza…); null when it
 *  doesn't — most keys start with a bare "sk-", and a key is never tried on a service to find out. */
export function detectKey(key: string): string | null {
  const k = key.trim();
  return TEXT_PRESETS.find((p) => p.keyPrefixes.some((x) => k.startsWith(x)))?.id ?? null;
}

/** The system region's pick: mainland China → the China address, anywhere else → the international one. */
export function systemRegion(langs: readonly string[] = typeof navigator === 'undefined' ? [] : [navigator.language, ...(navigator.languages ?? [])]): Region {
  return langs.some((l) => /-CN$/i.test(l) || /^zh-Hans$/i.test(l) || /^zh$/i.test(l)) ? 'china' : 'global';
}

/** an address's host ("api.example.com"): what a service of the user's own is called when it has no name */
export function hostOf(url: string): string {
  try {
    return new URL(url.trim()).host || url;
  } catch {
    return url;
  }
}
