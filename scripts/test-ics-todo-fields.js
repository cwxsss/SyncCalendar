// 验证 IcsUtil.rewriteTodoFields（改标题/备注/截止时间）
function escape(s) {
  return s.replace(/\\/g, '\\\\').replace(/;/g, '\\;').replace(/,/g, '\\,').replace(/\n/g, '\\n');
}
function fmtIcsTime(ms) {
  const pad = n => n < 10 ? '0' + n : String(n);
  const d = new Date(ms);
  return `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}T${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`;
}

function rewriteTodoFields(ics, uid, title, desc, dueMs) {
  const crlf = '\r\n';
  const unfolded = ics.replace(/\r?\n[ \t]/g, '');
  const lines = unfolded.split(/\r?\n/).map(s => s.replace(/\r$/, ''));
  const upperOf = s => s.toUpperCase();

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
  let sawSummary = false, sawDesc = false, sawDue = false;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i], u = upperOf(line);
    if (!(i > targetBegin && i < targetEnd)) { out.push(line); continue; }
    if (u.startsWith('SUMMARY')) { sawSummary = true; if (title !== '') out.push('SUMMARY:' + escape(title)); continue; }
    if (u.startsWith('DESCRIPTION')) { sawDesc = true; if (desc !== '') out.push('DESCRIPTION:' + escape(desc)); continue; }
    if (u.startsWith('DUE')) { sawDue = true; if (dueMs > 0) out.push('DUE:' + fmtIcsTime(dueMs)); continue; }
    out.push(line);
  }

  const extra = [];
  if (!sawSummary && title !== '') extra.push('SUMMARY:' + escape(title));
  if (!sawDesc && desc !== '') extra.push('DESCRIPTION:' + escape(desc));
  if (!sawDue && dueMs > 0) extra.push('DUE:' + fmtIcsTime(dueMs));
  if (extra.length === 0) { const p = out.join(crlf); return p.endsWith(crlf) ? p : p + crlf; }

  // 重新数目标块序号
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
      vtodoIdx = -1; result.push(out[i]); continue;
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
function balanced(ics, tag) {
  const b = (ics.match(new RegExp('BEGIN:' + tag, 'g')) || []).length;
  const e = (ics.match(new RegExp('END:' + tag, 'g')) || []).length;
  return b === e;
}

// 原始：含 PRIORITY / CATEGORIES / X-扩展 —— 这些必须原样保留（防丢数据）
const ics1 = 'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VTODO\r\nUID:t1\r\nDTSTAMP:20260101T000000Z\r\nSUMMARY:旧标题\r\nDESCRIPTION:旧备注\r\nDUE:20260105T090000Z\r\nPRIORITY:1\r\nCATEGORIES:家务,生活\r\nX-MY-EXT:hello\r\nSTATUS:NEEDS-ACTION\r\nPERCENT-COMPLETE:0\r\nEND:VTODO\r\nEND:VCALENDAR\r\n';

const due = new Date(2026, 2, 15, 14, 30, 0).getTime();
const r1 = rewriteTodoFields(ics1, 't1', '新标题', '新备注', due);

ok('标题已更新', r1.includes('SUMMARY:新标题'));
ok('旧标题已消失', !r1.includes('SUMMARY:旧标题'));
ok('备注已更新', r1.includes('DESCRIPTION:新备注'));
ok('截止时间已更新', /DUE:\d{8}T\d{6}/.test(r1) && !r1.includes('DUE:20260105'));
ok('⭐ 保留 PRIORITY', r1.includes('PRIORITY:1'));
ok('⭐ 保留 CATEGORIES', r1.includes('CATEGORIES:家务,生活') || r1.includes('CATEGORIES:家务\\,生活'));
ok('⭐ 保留 X-MY-EXT', r1.includes('X-MY-EXT:hello'));
ok('⭐ 保留 STATUS', r1.includes('STATUS:NEEDS-ACTION'));
ok('⭐ 结构完整', structureIntact(r1));
ok('BEGIN/END VTODO 配对', balanced(r1, 'VTODO'));

// 清除截止时间
const r2 = rewriteTodoFields(ics1, 't1', '旧标题', '旧备注', 0);
ok('截止时间可清除', !/DUE:\d{8}/.test(r2));
ok('清除后仍保留其他字段', r2.includes('PRIORITY:1'));

// 特殊字符转义（分号/逗号/换行）
const r3 = rewriteTodoFields(ics1, 't1', '标题;含逗号,和换行\n第二行', '', due);
ok('⭐ 特殊字符已转义', r3.includes('SUMMARY:标题\\;含逗号\\,和换行\\n第二行'), r3.match(/SUMMARY:[^\r]*/)?.[0]);

// uid 不匹配 → 原文不动
ok('uid 不匹配 → 原文不变', rewriteTodoFields(ics1, 'nope', 'x', 'y', due) === ics1);

// 缺 SUMMARY/DESCRIPTION 的极简待办 → 补齐
const ics4 = 'BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:t2\r\nEND:VTODO\r\nEND:VCALENDAR\r\n';
const r4 = rewriteTodoFields(ics4, 't2', '补的标题', '补的备注', due);
ok('缺字段能补齐', r4.includes('SUMMARY:补的标题') && r4.includes('DESCRIPTION:补的备注') && /DUE:/.test(r4));
ok('⭐ 补齐在 VTODO 内', structureIntact(r4) && (() => {
  const b = r4.substring(r4.indexOf('BEGIN:VTODO'), r4.indexOf('END:VTODO'));
  return b.includes('SUMMARY:补的标题');
})());

// 多 VTODO 只改目标
const ics5 = 'BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:a1\r\nSUMMARY:第一个\r\nEND:VTODO\r\nBEGIN:VTODO\r\nUID:a2\r\nSUMMARY:第二个\r\nEND:VTODO\r\nEND:VCALENDAR\r\n';
const r5 = rewriteTodoFields(ics5, 'a2', '改后', '', due);
ok('多 VTODO：a1 未动', r5.split('UID:a1')[1].split('END:VTODO')[0].includes('SUMMARY:第一个'));
ok('多 VTODO：a2 已改', r5.split('UID:a2')[1].split('END:VTODO')[0].includes('SUMMARY:改后'));
ok('⭐ 多 VTODO 结构完整', structureIntact(r5));

console.log(`\n结果：通过 ${pass}，失败 ${fail}`);
console.log('\n--- 测试1 输出 ---');
console.log(r1.replace(/\r\n/g, '\n'));
process.exit(fail === 0 ? 0 : 1);