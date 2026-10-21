// The one line to change when WP3's shared review component merges:
//   export { mountReview } from '@blurt/review';
// (and add "@blurt/review": "workspace:*" to package.json). Until then a local stand-in with the same C6 contract.
export { mountReview } from './stub';
export type { BlurtHost, MountOptions, SessionDoc, UserOp, Item, ReviewHandle } from './types';
