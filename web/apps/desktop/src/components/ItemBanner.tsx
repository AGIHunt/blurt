// The line above an item's detail (the Mac's ItemBanner in WebHostController.swift): who has the item and how that is
// going, with the one or two things to do about it — 44 px, a quiet wash of the tone (brand / neutral), the icon at
// the detail's inset, the sentence, the buttons at the right (one of them the brand primary), the rest in ⋯.
// What it says and offers comes from places.ts bannerPlan.
import { Icon } from '@blurt/icons';
import { StatusRing } from '@blurt/ui/react';
import type { ItemRow } from '../api';
import { menuCase } from '@blurt/ui';
import { t } from '../i18n';
import type { BannerPlan } from '../places';

export function bannerTitle(a: string): string {
  switch (a) {
    case 'progress':
      return t('main.banner.show_progress');
    default:
      return menuCase(t(`action.${a}`)); // done, wontfix
  }
}

export function ItemBanner({ row, plan, text, onAction, onMore }: {
  row: ItemRow;
  plan: BannerPlan;
  /** the sentence, resolved */
  text: string;
  onAction: (a: string) => void;
  onMore: (el: HTMLElement) => void;
}) {
  return (
    <div className={`mw-banner tone-${plan.tone}`} role="group" aria-label={text} data-testid="item-banner">
      <span className="mw-banner-ic">
        {plan.icon === 'spinner' ? <span className="mw-spinner sm" /> : <StatusRing state={row.state} size={16} />}
      </span>
      <span className="mw-banner-text" title={text}>{text}</span>
      <span className="mw-banner-acts">
        {plan.actions.map((a) => (
          <button key={a} className={a === plan.primary ? 'primary' : ''} onClick={() => onAction(a)}>
            {bannerTitle(a)}
          </button>
        ))}
        {plan.more.length > 0 && (
          <button className="icon-btn" aria-label={t('main.banner.more')} title={t('main.banner.more')} onClick={(e) => onMore(e.currentTarget)}>
            <Icon name="more" size={16} />
          </button>
        )}
      </span>
    </div>
  );
}
