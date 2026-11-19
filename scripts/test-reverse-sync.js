// scripts/test-reverse-sync.js
// 验证反向同步的判定逻辑（diffWithRow / normSet / 冲突策略）
// 用法：node scripts/test-reverse-sync.js
//
// 为什么用纯函数单测而不是真机测：
//   反向同步要求 WRITE_CONTACTS 权限（system_basic），
//   本构建装不上也授予不了，真机上 syncFromSystem 永远被 permOk 挡住。
//   但「判定逻辑是否正确」是可以独立验证的 —— 这正是最容易写错的部分。

let pass = 0;
let fail = 0;

function ok(name, cond, detail) {
  if (cond) { pass++; console.log(`  ✅ ${name}`); }
  else { fail++; console.log(`  ❌ ${name}` + (detail ? `  → ${detail}` : '')); }
}

function eq(name, actual, expected) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  ok(name, a === e, `实际 ${a}，期望 ${e}`);
}

// ───── 抄自 ContactService 的逻辑 ─────

function normSet(list) {
  const cleaned = list.map(v => v.trim()).filter(v => v !== '');
  cleaned.sort();
  return cleaned.join('|');
}

function diffWithRow(row, sys) {
  const d = { changed: false, name: '' };
  d.name = sys.displayName !== '' ? sys.displayName : row.displayName;
  if (sys.displayName !== row.displayName) { d.changed = true; return d; }
  if (sys.org !== row.org || sys.title !== row.title || sys.note !== row.note) {
    d.changed = true; return d;
  }
  const localPhones = row.phones.map(p => p.value);
  const sysPhones = sys.phones.map(p => p.value);
  if (normSet(localPhones) !== normSet(sysPhones)) { d.changed = true; return d; }
  const localEmails = row.emails.map(e => e.value);
  const sysEmails = sys.emails.map(e => e.value);
  if (normSet(localEmails) !== normSet(sysEmails)) d.changed = true;
  return d;
}

function row(o) {
  return {
    displayName: o.displayName || '',
    org: o.org || '',
    title: o.title || '',
    note: o.note || '',
    phones: (o.phones || []).map(v => ({ value: v, type: '' })),
    emails: (o.emails || []).map(v => ({ value: v, type: '' }))
  };
}

function sys(o) {
  return {
    displayName: o.displayName || '',
    org: o.org || '',
    title: o.title || '',
    note: o.note || '',
    phones: (o.phones || []).map(v => ({ value: v, type: '' })),
    emails: (o.emails || []).map(v => ({ value: v, type: '' }))
  };
}

console.log('\n=== 1. 完全一致 → 不应判定为改动 ===');
const base = row({ displayName: '张三', org: 'A公司', title: '工程师',
  note: 'n', phones: ['13800138000'], emails: ['a@b.com'] });
eq('无改动', diffWithRow(base, sys({ displayName: '张三', org: 'A公司',
  title: '工程师', note: 'n', phones: ['13800138000'], emails: ['a@b.com'] })).changed, false);

console.log('\n=== 2. 各字段单独改动都能识别 ===');
eq('改姓名', diffWithRow(base, sys({ displayName: '张三丰', org: 'A公司',
  title: '工程师', note: 'n', phones: ['13800138000'], emails: ['a@b.com'] })).changed, true);
eq('改公司', diffWithRow(base, sys({ displayName: '张三', org: 'B公司',
  title: '工程师', note: 'n', phones: ['13800138000'], emails: ['a@b.com'] })).changed, true);
eq('改职位', diffWithRow(base, sys({ displayName: '张三', org: 'A公司',
  title: '总监', note: 'n', phones: ['13800138000'], emails: ['a@b.com'] })).changed, true);
eq('改备注', diffWithRow(base, sys({ displayName: '张三', org: 'A公司',
  title: '工程师', note: '新备注', phones: ['13800138000'], emails: ['a@b.com'] })).changed, true);
eq('改电话', diffWithRow(base, sys({ displayName: '张三', org: 'A公司',
  title: '工程师', note: 'n', phones: ['13900139000'], emails: ['a@b.com'] })).changed, true);
eq('改邮箱', diffWithRow(base, sys({ displayName: '张三', org: 'A公司',
  title: '工程师', note: 'n', phones: ['13800138000'], emails: ['x@y.com'] })).changed, true);

console.log('\n=== 3. 电话顺序变化不该算改动 ===');
eq('两个电话顺序对调', diffWithRow(
  row({ displayName: '李四', phones: ['111', '222'] }),
  sys({ displayName: '李四', phones: ['222', '111'] })).changed, false);

console.log('\n=== 4. 空白差异不该算改动 ===');
eq('电话前后空格', diffWithRow(
  row({ displayName: '王五', phones: ['138 0013 8000'] }),
  sys({ displayName: '王五', phones: ['  138 0013 8000  '] })).changed, false);
eq('空电话项被忽略', diffWithRow(
  row({ displayName: '王五', phones: ['138', ''] }),
  sys({ displayName: '王五', phones: ['138'] })).changed, false);

console.log('\n=== 5. 增删电话 ===');
eq('新增一个电话', diffWithRow(
  row({ displayName: '赵六', phones: ['111'] }),
  sys({ displayName: '赵六', phones: ['111', '222'] })).changed, true);
eq('删掉一个电话', diffWithRow(
  row({ displayName: '赵六', phones: ['111', '222'] }),
  sys({ displayName: '赵六', phones: ['111'] })).changed, true);

console.log('\n=== 6. 系统侧 displayName 为空时的兜底 ===');
const d6 = diffWithRow(row({ displayName: '原名字', phones: [] }),
  sys({ displayName: '', phones: [] }));
ok('名字用本地值兜底', d6.name === '原名字', `实际 ${d6.name}`);
// displayName 空 vs 非空 → 算改动（系统里被清空了名字）
eq('系统清空名字算改动', d6.changed, true);

console.log('\n=== 7. normSet 本身 ===');
eq('排序去空', normSet(['b', ' a ', '', 'c']), 'a|b|c');
eq('全空得空串', normSet(['', '  ']), '');
eq('重复保留（不清重）', normSet(['a', 'a']), 'a|a');

console.log('\n=== 8. 冲突策略（远端 ETag 变化 → 远端优先）===');
// 模拟判定函数：本地记录的 etag vs 远端当前 etag
function shouldPushUp(localEtag, remoteEtag, sysChanged) {
  if (!sysChanged) return 'skip';
  if (remoteEtag !== '' && localEtag !== '' && remoteEtag !== localEtag) {
    return 'conflict';   // 远端也变了 → 放弃上行
  }
  return 'push';
}
eq('远端未变 → 上行', shouldPushUp('e1', 'e1', true), 'push');
eq('远端已变 → 冲突跳过', shouldPushUp('e1', 'e2', true), 'conflict');
eq('系统侧无改动 → 跳过', shouldPushUp('e1', 'e2', false), 'skip');
eq('远端 etag 拿不到 → 仍然上行（保守偏向不丢用户改动）',
  shouldPushUp('e1', '', true), 'push');

console.log('\n' + '='.repeat(46));
console.log(`结果：通过 ${pass}，失败 ${fail}`);
console.log('='.repeat(46));
process.exit(fail === 0 ? 0 : 1);