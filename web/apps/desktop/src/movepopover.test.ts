import { describe, expect, it } from 'vitest';
import { splitMiddle } from './components/MovePopover';

describe('splitMiddle', () => {
  it('leaves a short name whole', () => {
    expect(splitMiddle('Atlas Web', 34)).toEqual(['Atlas Web', '']);
  });
  it('never starts the tail inside a Latin word', () => {
    const [head, tail] = splitMiddle('现场巡检 App（安卓优先的 React Native 客户端）以及更多的说明文字在这里继续写下去', 20);
    expect(head.length).toBeGreaterThan(0);
    expect(tail).not.toMatch(/^[a-z]/);
  });
});
