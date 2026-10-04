export type Session = 'regular' | 'pre' | 'post' | 'overnight' | 'weekend';

/** Rough US/Eastern session label for dry-run logs (DST-aware via Intl). */
export function sessionAt(date = new Date()): Session {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: 'America/New_York',
    weekday: 'short',
    hour: 'numeric',
    minute: 'numeric',
    hour12: false,
  }).formatToParts(date);
  const weekday = parts.find((p) => p.type === 'weekday')?.value || '';
  const hour = Number(parts.find((p) => p.type === 'hour')?.value);
  const minute = Number(parts.find((p) => p.type === 'minute')?.value);
  const mins = hour * 60 + minute;

  const isWeekend = weekday === 'Sat' || weekday === 'Sun';
  // Fri 20:00 → Sun 20:00 treated as weekend book
  if (weekday === 'Sat' || weekday === 'Sun') return 'weekend';
  if (weekday === 'Fri' && mins >= 20 * 60) return 'weekend';
  if (isWeekend) return 'weekend';

  if (mins >= 9 * 60 + 30 && mins < 16 * 60) return 'regular';
  if (mins >= 4 * 60 && mins < 9 * 60 + 30) return 'pre';
  if (mins >= 16 * 60 && mins < 20 * 60) return 'post';
  return 'overnight';
}
