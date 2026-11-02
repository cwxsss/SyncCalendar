// 验证 IcsUtil.rewriteTodoCompletion（第二版：按结构定位插入点）
function fmtUtcNow() {
  return new Date().toISOString().replace(/[-:]/g, '').split('.')[0] + 'Z';
}

function rewrite(ics, uid, done) {
  const crlf = '\r\n';
  const unfolded = ics.replace(/\r?\n[ \t]/g, '');
  const lines = unfolded.split(/\r?\n/).map(s => s.replace(/\r$/, ''));
  const upperOf = s => s.toUpperCase();
  const nowUtc = fmtUtcNow();

  let targetBegin = -1, targetEnd = -1, targetOrdinal = -1;
  let curBegin = -1, curHasUid = false, blockIdx = -1;
  for (let i = 0; i < lines.length; i++) {
    const u = upperOf(lines[i]);
    if (u.startsWith('BEGIN:VTODO')) { blockIdx++; curBegin = i; curHasUid = false; continue; }
    if (u.startsWith('UID:') && curBegin >= 0) {
      if (lines[i].substring(4).trim() === uid) curHasUid = true;
      continue;
    }
    if (u.startsWith('END:VTODO')) {
      if (curBegin >= 0 && curHasUid && targetBegin < 0) {
        targetBegin = curBegin; targetEnd = i; targetOrdinal = blockIdx;
      }
      curBegin = -1; curHasUid = false;
    }
  }
  if (targetBegin < 0) return ics;

  const out = [];
  let sawStatus = false, sawPercent = false;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i], u = upperOf(line);
    if (!(i > targetBegin && i < targetEnd)) { out.push(line); continue; }
    if (u.startsWith('STATUS:')) { sawStatus = true; out.push(done ? 'STATUS:COMPLETED' : 'STATUS:NEEDS-ACTION'); continue; }
    if (u.startsWith('COMPLETED')) { continue; }
    if (u.startsWith('PERCENT-COMPLETE')) { sawPercent = true; out.push(done ? 'PERCENT-COMPLETE:100' : 'PERCENT-COMPLETE:0'); continue; }
    out.push(line);
  }

  const extra = [];
  if (!sawStatus) extra.push(done ? 'STATUS:COMPLETED' : 'STATUS:NEEDS-ACTION');
  if (done) extra.push('COMPLETED:' + nowUtc);
  if (!sawPercent) extra.push(done ? 'PERCENT-COMPLETE:100' : 'PERCENT-COMPLETE:0');
  if (extra.length === 0) {
    const plain = out.join(crlf);
    return plain.endsWith(crlf) ? plain : plain + crlf;
  }

  const result = [];
  let vtodoIdx = -1, inserted = false;
  for (let i = 0; i < out.length; i++) {
    const u = upperOf(out[i]);
    if (u.startsWith('BEGIN:VTODO')) { vtodoIdx++; result.push(out[i]); continue; }
    if (u.startsWith('END:VTODO')) {
      if (!inserted && vtodoIdx === targetOrdinal) {
        for (const ex of extra) result.push(ex);
        inserted = true;
      }
      vtodoIdx = -1; result.push(out[i]); continue;
    }
    result.push(out[i]);
  }
  if (!inserted) {
    const tail0 = result.join(crlf);
    const idxVc = tail0.lastIndexOf('END:VCALENDAR');
    if (idxVc > 0) {
      const merged = tail0.substring(0, idxVc) + extra.join(crlf) + crlf + tail0.substring(idxVc);
      return merged.endsWith(crlf) ? merged : merged + crlf;
    }
    for (const ex of extra) result.push(ex);
  }
  const text2 = result.join(crlf);
  return text2.endsWith(crlf) ? text2 : text2 + crlf;
}

let pass = 0, fail = 0;
function assert(name, cond, detail) {
  if (cond) { console.log('  ✅', name); pass++; }
  else { console.log('  ❌', name, detail || ''); fail++; }
}

/** 关键结构校验：任何字段都不能跑到 END:VCALENDAR 之后 */
function structureIntact(ics) {
  const iEnd = ics.indexOf('END:VCALENDAR');
  if (iEnd < 0) return false;
  const after = ics.substring(iEnd + 'END:VCALENDAR'.length).replace(/[\r\n]/g, '');
  return after === '';   // END:VCALENDAR 之后不应有任何内容
}
function balanced(ics, tag) {
  const b = (ics.match(new RegExp('BEGIN:' + tag, 'g')) || []).length;
  const e = (ics.match(new RegExp('END:' + tag, 'g')) || []).length;
  return b === e;
}

// 1. STATUS 在 UID 之前（触发补字段的路径）
const ics1 = 'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VTODO\r\nDTSTAMP:20260101T000000Z\r\nSTATUS:NEEDS-ACTION\r\nSUMMARY:买菜\r\nUID:todo-abc-123\r\nDUE:20260105T090000Z\r\nEND:VTODO\r\nEND:VCALENDAR\r\n';
const r1 = rewrite(ics1, 'todo-abc-123', true);
assert('STATUS 在 UID 之前 → COMPLETED', r1.includes('STATUS:COMPLETED'));
assert('旧状态消失', !r1.includes('STATUS:NEEDS-ACTION'));
assert('有 COMPLETED 时间戳', /COMPLETED:\d{8}T\d{6}Z/.test(r1));
assert('补 PERCENT-COMPLETE:100', r1.includes('PERCENT-COMPLETE:100'));
assert('保留 SUMMARY', r1.includes('SUMMARY:买菜'));
assert('保留 DUE', r1.includes('DUE:20260105T090000Z'));
assert('⭐ 结构完整（END:VCALENDAR 后无残留）', structureIntact(r1), JSON.stringify(r1.slice(r1.indexOf('END:VCALENDAR'))));
assert('BEGIN/END VTODO 配对', balanced(r1, 'VTODO'));

// 2. UID 在前 + 已有 STATUS/PERCENT（不触发补字段）
const ics2 = 'BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:todo-xyz\r\nDTSTAMP:20260101T000000Z\r\nSUMMARY:写报告\r\nPRIORITY:1\r\nSTATUS:NEEDS-ACTION\r\nPERCENT-COMPLETE:0\r\nEND:VTODO\r\nEND:VCALENDAR\r\n';
const r2 = rewrite(ics2, 'todo-xyz', true);
assert('UID 在前 → COMPLETED', r2.includes('STATUS:COMPLETED'));
assert('PERCENT 改 100', r2.includes('PERCENT-COMPLETE:100'));
assert('保留 SUMMARY/PRIORITY', r2.includes('SUMMARY:写报告') && r2.includes('PRIORITY:1'));
assert('⭐ 结构完整', structureIntact(r2));
assert('COMPLETED 时间戳在 VTODO 内部', (() => {
  const body = r2.substring(r2.indexOf('BEGIN:VTODO'), r2.indexOf('END:VTODO'));
  return /COMPLETED:\d{8}/.test(body);
})());

// 3. 取消完成
const ics3 = 'BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:todo-xyz\r\nSTATUS:COMPLETED\r\nCOMPLETED:20260101T000000Z\r\nPERCENT-COMPLETE:100\r\nSUMMARY:写报告\r\nEND:VTODO\r\nEND:VCALENDAR\r\n';
const r3 = rewrite(ics3, 'todo-xyz', false);
assert('取消完成 → NEEDS-ACTION', r3.includes('STATUS:NEEDS-ACTION'));
assert('PERCENT 回 0', r3.includes('PERCENT-COMPLETE:0'));
assert('COMPLETED 行被移除', !/COMPLETED:\d{8}/.test(r3));
assert('⭐ 结构完整', structureIntact(r3));

// 4. uid 不匹配 → 原文不动
assert('uid 不匹配 → 原文不变', rewrite(ics1, 'nope', true) === ics1);

// 5. 多 VTODO 只改目标
const ics5 = 'BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:a1\r\nSUMMARY:第一个\r\nSTATUS:NEEDS-ACTION\r\nEND:VTODO\r\nBEGIN:VTODO\r\nUID:a2\r\nSUMMARY:第二个\r\nSTATUS:NEEDS-ACTION\r\nEND:VTODO\r\nEND:VCALENDAR\r\n';
const r5 = rewrite(ics5, 'a2', true);
assert('多 VTODO：a1 未动', r5.split('UID:a1')[1].split('END:VTODO')[0].includes('STATUS:NEEDS-ACTION'));
assert('多 VTODO：a2 已改', r5.split('UID:a2')[1].split('END:VTODO')[0].includes('STATUS:COMPLETED'));
assert('⭐ 多 VTODO 结构完整', structureIntact(r5));
assert('两个 VTODO 都配对', balanced(r5, 'VTODO'));

// 6. 目标 VTODO 缺 STATUS（走"补字段"最极端路径）
const ics6 = 'BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:bare\r\nSUMMARY:没有状态字段\r\nEND:VTODO\r\nEND:VCALENDAR\r\n';
const r6 = rewrite(ics6, 'bare', true);
assert('缺 STATUS 时能补上', r6.includes('STATUS:COMPLETED'));
assert('⭐ 补在 VTODO 内而非 VCALENDAR 后', structureIntact(r6) && (() => {
  const body = r6.substring(r6.indexOf('BEGIN:VTODO'), r6.indexOf('END:VTODO'));
  return body.includes('STATUS:COMPLETED');
})());

// 7. 折行保留
const ics7 = 'BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:long\r\nSUMMARY:很长的标题\r\n 需要折行\r\nSTATUS:NEEDS-ACTION\r\nEND:VTODO\r\nEND:VCALENDAR\r\n';
assert('折行被还原保留', rewrite(ics7, 'long', true).includes('很长的标题需要折行'));

// 8. 末尾多个空行也不应让结构崩
const ics8 = ics1 + '\r\n\r\n';
assert('⭐ 尾部空行场景结构完整', structureIntact(rewrite(ics8, 'todo-abc-123', true)));

console.log(`\n结果：通过 ${pass}，失败 ${fail}`);
console.log('\n--- 测试1 输出 ---');
console.log(r1.replace(/\r\n/g, '\n'));
console.log('--- 测试6 输出（最极端：无 STATUS）---');
console.log(r6.replace(/\r\n/g, '\n'));
process.exit(fail === 0 ? 0 : 1);