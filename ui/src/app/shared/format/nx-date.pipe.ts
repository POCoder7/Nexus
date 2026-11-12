import { Pipe, PipeTransform } from '@angular/core';

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/**
 * `dd MMM yyyy` for business dates (UI_STANDARD §7, e.g. 03 Feb 2027). An ISO date (yyyy-MM-dd) is formatted as written,
 * with no time zone shift: it is a business date, not an instant.
 */
export function formatBusinessDate(iso: string | null | undefined): string {
  if (!iso) {
    return '—';
  }
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(iso);
  return m ? `${m[3]} ${MONTHS[Number(m[2]) - 1]} ${m[1]}` : iso;
}

/** 24-hour date and time with the time zone shown (UI_STANDARD §7), in the business time zone. */
export function formatInstant(iso: string | null | undefined, timeZone = 'America/New_York'): string {
  if (!iso) {
    return '—';
  }
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) {
    return iso;
  }
  const parts = new Intl.DateTimeFormat('en-GB', {
    timeZone, day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false,
    timeZoneName: 'short',
  }).formatToParts(d);
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? '';
  return `${get('day')} ${get('month')} ${get('year')} ${get('hour')}:${get('minute')} ${get('timeZoneName')}`;
}

/** The ISO date one day before `iso` (for "as of the day before"). */
export function previousDay(iso: string): string {
  const d = new Date(`${iso}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() - 1);
  return d.toISOString().slice(0, 10);
}

@Pipe({ name: 'nxDate' })
export class NxDatePipe implements PipeTransform {
  transform(value: string | null | undefined): string {
    return formatBusinessDate(value);
  }
}

@Pipe({ name: 'nxInstant' })
export class NxInstantPipe implements PipeTransform {
  transform(value: string | null | undefined, timeZone?: string): string {
    return formatInstant(value, timeZone);
  }
}
