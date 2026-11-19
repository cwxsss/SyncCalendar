// 验证待办循环：incForFreq 与 rewriteTodoRecurrence
function fmtIcsTime(ms) {
  const pad = n => n < 10 ? '0' + n : String(n);
  const d = new Date(ms);
  return `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}T${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`;
}
function freqOfRrule(rrule) {
  for (const part of rrule.split(';')) {
    const i = part.indexOf('=');
    if (i <= 0) continue;
    if (part.substring(0, i).trim().toUpperCase() === 'FREQ') {
      return part.substring(i + 1).trim().toUpperCase();
    }
  }
  return 'DAILY';
}
function incForFreq(freq, fromMs) {
  const d = new Date(fromMs), f = freq.toUpperCase();
  if (f === 'DAILY') return fromMs + 86400000;
  if (f === 'WEEKLY') return fromMs + 7 * 86400000;
  if (f === 'MONTHLY') {
    const y = d.getFullYear(), m = d.getMonth() + 1, day = d.getDate();
    const last = new Date(y, m + 1, 0).getDate();
    return new Date(y, m, Math.min(day, last), d.getHours(), d.getMinutes(), d.getSeconds()).getTime();
  }
  if (f === 'YEARLY') {
    const y = d.getFullYear() + 1, m = d.getMonth(), day = d.getDate();
    const last = new Date(y, m + 1, 0).getDate();
    return new Date(y, m, Math.min(day, last), d.getHours(), d.getMinutes(), d.getSeconds()).getTime();
  }
  return fromMs + 86400000;
}

function rewriteTodoRecurrence(ics, uid, rrule, dtstart, dueMs) {
  const crlf = '\r\n';
  const unfolded = ics.replace(/\r?\n[ \t]/g, '');
  const lines = unfolded.split(/\r?\n/).map(s => s.replace(/\r$/, ''));
  const upperOf = s => s.toUpperCase();
  const hasRule = rrule.trim() !== '';

  let targetBegin = -1, targetEnd = -1, curBegin = -1, curHasUid = false;
  for (let i = 0; i < lines.length; i++) {
    const u = upperOf(lines[i]);
    if (u.startsWith('BEGIN:VTODO')) { curBegin = i; curHasUid = false; continue; }
    if (u.startsWith('UID:') && curBegin >= 0) {
      if (lines[i].substring(4).trim() === uid) curHasUid = true;
      continue;
    }
    if (u.startsWith('END:VTODO')) {
      if (curBegin >= 0 && curHasUid && targetBegin < 0) { targetBegin = curBegin; targetEnd = i; }
      curBegin = -1; curHasUid = false;
    }
  }
  if (targetBegin < 0) return ics;

  const out = [];
  let sawRule = false, sawStart = false, sawDue = false;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i], u = upperOf(line);
    if (!(i > targetBegin && i < targetEnd)) { out.push(line); continue; }
    if (u.startsWith('RRULE')) { sawRule = true; if (hasRule) out.push('RRULE:' + rrule.trim()); continue; }
    if (u.startsWith('DTSTART')) { sawStart = true; if (hasRule && dtstart > 0) out.push('DTSTART:' + fmtIcsTime(dtstart)); continue; }
    if (u.startsWith('DUE')) { sawDue = true; if (dueMs > 0) out.push('DUE:' + fmtIcsTime(dueMs)); continue; }
    out.push(line);
  }

  const extra = [];
  if (hasRule) {
    if (!sawRule) extra.push('RRULE:' + rrule.trim());
    if (!sawStart && dtstart > 0) extra.push('DTSTART:' + fmtIcsTime(dtstart));
    if (!sawDue && dueMs > 0) extra.push('DUE:' + fmtIcsTime(dueMs));
  }
  if (extra.length === 0) { const p = out.join(crlf); return p.endsWith(crlf) ? p : p + crlf; }

  let targetOrdinal = -1;
  {
    let n = -1, inBlk = false, has = false;
    for (let i = 0; i < out.length; i++) {
      const u = upperOf(out[i]);
      if (u.startsWith('BEGIN:VTODO')) { n++; inBlk = true; has = false; continue; }
      if (u.startsWith('UID:') && inBlk && out[i].substring(4).trim() === uid) { has = true; continue; }
      if (u.startsWith('END:VTODO') && inBlk) { if (has && targetOrdinal < 0) targetOrdinal = n; inBlk = false; }
    }
  }
  const result = [];
  let vtodoIdx = -1, inserted = false;
  for (let i = 0; i < out.length; i++) {
    const u = upperOf(out[i]);
    if (u.startsWith('BEGIN:VTODO')) { vtodoIdx++; result.push(out[i]); continue; }
    if (u.startsWith('END:VTODO')) {
      if (!inserted && vtodoIdx === targetOrdinal) { for (const e of extra) result.push(e); inserted = true; }
      result.push(out[i]); continue;
    }
    result.push(out[i]);
  }
  if (!inserted) {
    const t0 = result.join(crlf);
    const iv = t0.lastIndexOf('END:VCALENDAR');
    if (iv > 0) {
      const m = t0.substring(0, iv) + extra.join(crlf) + crlf + t0.substring(iv);
      return m.endsWith(crlf) ? m : m + crlf;
    }
    for (const e of extra) result.push(e);
  }
  const t2 = result.join(crlf);
  return t2.endsWith(crlf) ? t2 : t2 + crlf;
}

let pass = 0, fail = 0;
function ok(name, cond, extra) {
  if (cond) { console.log('  ✅', name); pass++; }
  else { console.log('  ❌', name, extra || ''); fail++; }
}
function structureIntact(ics) {
  const i = ics.indexOf('END:VCALENDAR');
  if (i < 0) return false;
  return ics.substring(i + 'END:VCALENDAR'.length).replace(/[\r\n]/g, '') === '';
}

// ===== 1. incForFreq 各种边界 =====
const d0 = new Date(2026, 0, 31, 9, 0, 0).getTime();  // 2026-01-31 09:00
const m1 = new Date(incForFreq('MONTHLY', d0));
ok('1/31 + 1月 → 2/28（钳制，不跳到3月）',
  m1.getMonth() === 1 && m1.getDate() === 28, `${m1.getMonth() + 1}/${m1.getDate()}`);
ok('  时分保持不变（09:00）', m1.getHours() === 9 && m1.getMinutes() === 0);

const leap = new Date(2024, 1, 29, 9, 0, 0).getTime(); // 2024-02-29
const y1 = new Date(incForFreq('YEARLY', leap));
ok('2/29 + 1年 → 2/28（次年无29日）', y1.getMonth() === 1 && y1.getDate() === 28,
  `${y1.getFullYear()}-${y1.getMonth() + 1}-${y1.getDate()}`);

const w = new Date(incForFreq('WEEKLY', d0));
ok('每周 = +7 天', (w.getTime() - d0) === 7 * 86400000);

const dd = new Date(incForFreq('DAILY', d0));
ok('每天 = +1 天', (dd.getTime() - d0) === 86400000);

// ===== 2. freqOfRrule =====
ok('freqOfRrule 取 WEEKLY', freqOfRrule('FREQ=WEEKLY;INTERVAL=2') === 'WEEKLY');
ok('freqOfRrule 无序也能取', freqOfRrule('INTERVAL=2;FREQ=DAILY') === 'DAILY');
ok('freqOfRrule 空规则回退 DAILY', freqOfRrule('') === 'DAILY');

// ===== 3. rewriteTodoRecurrence 写规则 =====
const ics1 = 'BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:t1\r\nSUMMARY:浇花\r\nDUE:20260110T090000\r\nSTATUS:NEEDS-ACTION\r\nPRIORITY:5\r\nEND:VTODO\r\nEND:VCALENDAR\r\n';
const due1 = new Date(2026, 0, 10, 9, 0, 0).getTime();
const r1 = rewriteTodoRecurrence(ics1, 't1', 'FREQ=WEEKLY', due1, due1);

ok('写入 RRULE', r1.includes('RRULE:FREQ=WEEKLY'));
ok('⭐ 同时写入 DTSTART（消除客户端歧义）', /DTSTART:\d{8}T\d{6}/.test(r1));
ok('DUE 保留', /DUE:\d{8}T\d{6}/.test(r1));
ok('⭐ 保留 PRIORITY（不丢字段）', r1.includes('PRIORITY:5'));
ok('⭐ 保留 STATUS', r1.includes('STATUS:NEEDS-ACTION'));
ok('⭐ 结构完整', structureIntact(r1));

// ===== 4. 取消循环 =====
const ics2 = r1;
const r2 = rewriteTodoRecurrence(ics2, 't1', '', 0, due1);
ok('取消循环 → RRULE 被删', !r2.includes('RRULE:'));
ok('取消循环 → DTSTART 被删', !r2.includes('DTSTART:'));
ok('取消循环 → DUE 保留', /DUE:\d{8}/.test(r2));
ok('⭐ 取消后结构完整', structureIntact(r2));

// ===== 5. 推进到下一轮（模拟 completeRecurringRound）=====
const base = due1;
const nextBase = incForFreq('WEEKLY', base);
const r3 = rewriteTodoRecurrence(ics1, 't1', 'FREQ=WEEKLY', nextBase, nextBase);
const mDt = r3.match(/DTSTART:(\d{8}T\d{6})/);
ok('⭐ 推进后 DTSTART 变成下一周', mDt !== null && mDt[1].startsWith('20260117'),
  mDt ? mDt[1] : 'no match');
ok('推进后 RRULE 不变', r3.includes('RRULE:FREQ=WEEKLY'));

// ===== 6. 多 VTODO 只改目标 =====
const ics6 = 'BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:a1\r\nSUMMARY:第一个\r\nDUE:20260101T090000\r\nEND:VTODO\r\nBEGIN:VTODO\r\nUID:a2\r\nSUMMARY:第二个\r\nDUE:20260102T090000\r\nEND:VTODO\r\nEND:VCALENDAR\r\n';
const r6 = rewriteTodoRecurrence(ics6, 'a2', 'FREQ=DAILY', due1, due1);
ok('多 VTODO：a1 未加 RRULE', !r6.split('UID:a1')[1].split('END:VTODO')[0].includes('RRULE'));
ok('多 VTODO：a2 已加 RRULE', r6.split('UID:a2')[1].split('END:VTODO')[0].includes('RRULE'));
ok('⭐ 多 VTODO 结构完整', structureIntact(r6));

// ===== 7. uid 不匹配 → 原文不动 =====
ok('uid 不匹配 → 原文不变', rewriteTodoRecurrence(ics1, 'nope', 'FREQ=DAILY', due1, due1) === ics1);

console.log(`\n结果：通过 ${pass}，失败 ${fail}`);
console.log('\n--- 写入循环后的 ICS ---');
console.log(r1.replace(/\r\n/g, '\n'));
process.exit(fail === 0 ? 0 : 1);