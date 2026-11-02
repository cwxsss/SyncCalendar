// 验证 preferredDay 机制消除日号漂移
function addMonths(y, m, delta) {
  let mm = m + delta, yy = y;
  while (mm < 0) { mm += 12; yy--; }
  while (mm > 11) { mm -= 12; yy++; }
  return [yy, mm];
}
function migrate(preferredDay, y, m, delta) {
  const nm = addMonths(y, m, delta);
  const lastDay = new Date(nm[0], nm[1] + 1, 0).getDate();
  return { ms: new Date(nm[0], nm[1], Math.min(preferredDay, lastDay)).getTime(), y: nm[0], m: nm[1] };
}
function fmt(ms) {
  const d = new Date(ms);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

let pass = 0, fail = 0;
function ok(name, cond, extra) {
  if (cond) { console.log('  ✅', name); pass++; }
  else { console.log('  ❌', name, extra); fail++; }
}

// 1. 偏好 31 号：1/31 → 2/28 → 3/31（回到 31！）
let pref = 31, y = 2026, m = 0, cur = new Date(2026, 0, 31).getTime(), log = [];
for (let i = 0; i < 4; i++) {
  const r = migrate(pref, y, m, 1);
  cur = r.ms; y = r.y; m = r.m;
  log.push(fmt(cur));
}
console.log('  偏好31号连续翻月:', log.join(' → '));
ok('1/31→2/28→3/31→4/30（月底语义保留）',
  log[0] === '2026-02-28' && log[1] === '2026-03-31' && log[2] === '2026-04-30',
  log.join(','));
ok('第4次翻到5月回到31', log[3] === '2026-05-31', log[3]);

// 2. 偏好 15 号：一直稳定
pref = 15; y = 2026; m = 0; log = [];
for (let i = 0; i < 6; i++) {
  const r = migrate(pref, y, m, 1);
  y = r.y; m = r.m; log.push(fmt(r.ms));
}
ok('偏好15号稳定', log.every(s => s.endsWith('-15')), log.join(','));

// 3. 用户点 2/28 后偏好变 28，翻到 3 月应是 28 号
pref = 28; y = 2026; m = 1;
let r = migrate(pref, y, m, 1);
ok('点过28号后翻月为3/28', fmt(r.ms) === '2026-03-28', fmt(r.ms));

// 4. 闰年偏好 31
pref = 31; y = 2028; m = 0;
r = migrate(pref, y, m, 1);
ok('闰年 1/31 → 2/29', fmt(r.ms) === '2028-02-29', fmt(r.ms));
r = migrate(pref, 2028, 1, 1);
ok('闰年 2/29 → 3/31', fmt(r.ms) === '2028-03-31', fmt(r.ms));

// 5. 往前翻同样保留
pref = 31; y = 2026; m = 2;  // 3月
r = migrate(pref, y, m, -1);
ok('3/31 上月 → 2/28', fmt(r.ms) === '2026-02-28', fmt(r.ms));
r = migrate(pref, 2026, 1, -1);
ok('2/28 再上月 → 1/31', fmt(r.ms) === '2026-01-31', fmt(r.ms));

console.log(`\n结果：通过 ${pass}，失败 ${fail}`);
process.exit(fail === 0 ? 0 : 1);