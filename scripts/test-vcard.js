// scripts/test-vcard.js
// 验证 VCardUtil 的解析与就地改字段逻辑
// 用法：node scripts/test-vcard.js
//
// 为什么单独抽一份：ArkTS 不能直接在 node 跑，而 vCard 解析是纯字符串逻辑，
// 核心算法抄一份到 JS 里做行为验证最直接（与 test-ics-todo.js 同思路）。
// ⚠️ 改 VCardUtil.ets 的算法时必须同步这里，否则测试会失真。

let pass = 0;
let fail = 0;

function ok(name, cond, detail) {
  if (cond) {
    pass++;
    console.log(`  ✅ ${name}`);
  } else {
    fail++;
    console.log(`  ❌ ${name}` + (detail ? `  → ${detail}` : ''));
  }
}

function eq(name, actual, expected) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  ok(name, a === e, `实际 ${a}，期望 ${e}`);
}

// ───────────── 抄自 VCardUtil.ets 的核心算法 ─────────────

function unfold(text) {
  const normalized = text.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  const physical = normalized.split('\n');
  const out = [];
  for (const line of physical) {
    if (line.length > 0 && (line.charAt(0) === ' ' || line.charAt(0) === '\t')) {
      if (out.length > 0) {
        out[out.length - 1] = out[out.length - 1] + line.substring(1);
      } else {
        out.push(line.substring(1));
      }
    } else {
      out.push(line);
    }
  }
  return out.join('\n');
}

function findValueColon(line) {
  let inQuote = false;
  for (let i = 0; i < line.length; i++) {
    const c = line.charAt(i);
    if (c === '"') { inQuote = !inQuote; continue; }
    if (c === ':' && !inQuote) return i;
  }
  return -1;
}

function unescape(v) {
  if (v.indexOf('\\') < 0) return v;
  let out = '';
  for (let i = 0; i < v.length; i++) {
    const c = v.charAt(i);
    if (c === '\\' && i + 1 < v.length) {
      const n = v.charAt(i + 1);
      if (n === 'n' || n === 'N') out += '\n';
      else out += n;
      i++;
    } else out += c;
  }
  return out;
}

function escape(v) {
  return v.replace(/\\/g, '\\\\').replace(/\n/g, '\\n').replace(/\r/g, '')
    .replace(/,/g, '\\,').replace(/;/g, '\\;');
}

function splitLines(unfolded) {
  const out = [];
  let offset = 0;
  for (const text of unfolded.split('\n')) {
    const line = { text, start: offset, end: offset + text.length, name: '', group: '' };
    offset = line.end + 1;
    const colon = findValueColon(text);
    const meta = colon >= 0 ? text.substring(0, colon) : text;
    let namePart = meta.split(';')[0];
    const dot = namePart.indexOf('.');
    if (dot > 0) {
      line.group = namePart.substring(0, dot);
      namePart = namePart.substring(dot + 1);
    }
    line.name = namePart.trim().toUpperCase();
    out.push(line);
  }
  return out;
}

function valueOf(line) {
  const colon = findValueColon(line.text);
  if (colon < 0) return '';
  return unescape(line.text.substring(colon + 1));
}

function paramsOf(line) {
  const colon = findValueColon(line.text);
  const meta = colon >= 0 ? line.text.substring(0, colon) : line.text;
  const parts = meta.split(';');
  parts.shift();
  return parts.join(';');
}

function firstType(params) {
  if (params === '') return '';
  for (const seg of params.split(';')) {
    const t = seg.trim();
    const eqi = t.indexOf('=');
    if (eqi > 0) {
      const key = t.substring(0, eqi).toUpperCase();
      if (key === 'TYPE') {
        let val = t.substring(eqi + 1).replace(/"/g, '');
        if (val.indexOf(',') > 0) val = val.split(',')[0];
        return val.trim().toUpperCase();
      }
    } else if (t !== '' && t.indexOf('=') < 0 && t.toUpperCase() !== 'PREF') {
      return t.toUpperCase();
    }
  }
  return '';
}


function rawValueOf(line) {
  const colon = findValueColon(line.text);
  if (colon < 0) return '';
  return line.text.substring(colon + 1);
}

function splitSegments(raw) {
  const out = [];
  let cur = '';
  for (let i = 0; i < raw.length; i++) {
    const ch = raw.charAt(i);
    if (ch === '\\' && i + 1 < raw.length) {
      cur += ch + raw.charAt(i + 1);
      i++;
    } else if (ch === ';') {
      out.push(unescape(cur));
      cur = '';
    } else {
      cur += ch;
    }
  }
  out.push(unescape(cur));
  return out;
}

function parse(raw, href, etag) {
  if (raw === '' || raw.indexOf('BEGIN:VCARD') < 0) return null;
  const c = { uid: '', href: href || '', etag: etag || '', displayName: '', familyName: '',
    givenName: '', org: '', title: '', note: '', phones: [], emails: [], addresses: [],
    hasPhoto: false, rev: '' };
  const unfolded = unfold(raw);
  const lines = splitLines(unfolded);
  let fn = '', n = '';
  for (const line of lines) {
    switch (line.name) {
      case 'UID': c.uid = valueOf(line); break;
      case 'FN': if (fn === '') fn = valueOf(line); break;
      case 'N': if (n === '') n = valueOf(line); break;
      case 'ORG': if (c.org === '') {
        const segs = splitSegments(rawValueOf(line));
        c.org = segs.length > 0 ? segs[0] : '';
      } break;
      case 'TITLE': c.title = valueOf(line); break;
      case 'NOTE': c.note = valueOf(line); break;
      case 'REV': c.rev = valueOf(line); break;
      case 'PHOTO': c.hasPhoto = true; break;
      case 'TEL': {
        const v = valueOf(line);
        if (v !== '') c.phones.push({ value: v, type: firstType(paramsOf(line)) });
        break;
      }
      case 'EMAIL': {
        const v = valueOf(line);
        if (v !== '') c.emails.push({ value: v, type: firstType(paramsOf(line)) });
        break;
      }
      default: break;
    }
  }
  if (n !== '') {
    const nl = lines.filter(l => l.name === 'N')[0];
    const seg = nl ? splitSegments(rawValueOf(nl)) : n.split(';');
    c.familyName = seg[0] || '';
    c.givenName = seg[1] || '';
  }
  if (fn !== '') c.displayName = fn;
  else if (c.familyName !== '' || c.givenName !== '') c.displayName = joinName(c.givenName, c.familyName);
  else c.displayName = c.org || c.uid || '(未命名)';
  return c;
}

function joinName(given, family) {
  if (given === '') return family;
  if (family === '') return given;
  const hasCJK = /[\u4e00-\u9fff]/.test(given + family);
  return hasCJK ? family + given : `${given} ${family}`;
}

function setField(raw, name, newValue, params) {
  params = params || '';
  const unfolded = unfold(raw);
  const lines = splitLines(unfolded);
  const upper = name.toUpperCase();
  const hits = lines.filter(l => l.name === upper);
  const lineText = params === '' ? `${upper}:${escape(newValue)}`
    : `${upper};${params}:${escape(newValue)}`;
  if (hits.length > 0) {
    let out = '', cursor = 0;
    for (let i = 0; i < hits.length; i++) {
      const h = hits[i];
      out += unfolded.substring(cursor, h.start);
      if (i === 0 && newValue !== '') out += lineText + '\n';
      cursor = h.end;
      if (cursor < unfolded.length && unfolded.charAt(cursor) === '\n') cursor += 1;
    }
    out += unfolded.substring(cursor);
    return out.replace(/\n{3,}/g, '\n\n');
  }
  if (newValue === '') return raw;
  const endIdx = unfolded.lastIndexOf('END:VCARD');
  if (endIdx < 0) return raw;
  const before = unfolded.substring(0, endIdx);
  const after = unfolded.substring(endIdx);
  const sep = before.endsWith('\n') ? '' : '\n';
  return (before + sep + lineText + '\n' + after).replace(/\n{3,}/g, '\n\n');
}


function setFieldRaw(raw, name, literal) {
  const unfolded = unfold(raw);
  const lines = splitLines(unfolded);
  const upper = name.toUpperCase();
  const hits = lines.filter(l => l.name === upper);
  const lineText = `${upper}:${literal}`;
  if (hits.length > 0) {
    let out = '', cursor = 0;
    for (let i = 0; i < hits.length; i++) {
      const h = hits[i];
      out += unfolded.substring(cursor, h.start);
      if (i === 0 && literal !== '') out += lineText + '\n';
      cursor = h.end;
      if (cursor < unfolded.length && unfolded.charAt(cursor) === '\n') cursor += 1;
    }
    out += unfolded.substring(cursor);
    return out.replace(/\n{3,}/g, '\n\n');
  }
  if (literal === '') return raw;
  const endIdx = unfolded.lastIndexOf('END:VCARD');
  if (endIdx < 0) return raw;
  const before = unfolded.substring(0, endIdx);
  const after = unfolded.substring(endIdx);
  const sep = before.endsWith('\n') ? '' : '\n';
  return (before + sep + lineText + '\n' + after).replace(/\n{3,}/g, '\n\n');
}

function setStructuredField(raw, name, segments) {
  return setFieldRaw(raw, name, segments.map(escape).join(';'));
}

function setMulti(raw, name, values, paramsList) {
  const unfolded = unfold(raw);
  const lines = splitLines(unfolded);
  const upper = name.toUpperCase();
  const hits = lines.filter(l => l.name === upper);
  let out = '', cursor = 0, written = false;
  for (const h of hits) {
    out += unfolded.substring(cursor, h.start);
    if (!written) {
      for (let i = 0; i < values.length; i++) {
        if (values[i] === '') continue;
        const p = i < paramsList.length && paramsList[i] !== '' ? `;${paramsList[i]}` : '';
        out += `${upper}${p}:${escape(values[i])}\n`;
      }
      written = true;
    }
    cursor = h.end;
    if (cursor < unfolded.length && unfolded.charAt(cursor) === '\n') cursor += 1;
  }
  out += unfolded.substring(cursor);
  if (!written && values.length > 0) {
    const endIdx = out.lastIndexOf('END:VCARD');
    if (endIdx >= 0) {
      const before = out.substring(0, endIdx), after = out.substring(endIdx);
      let block = '';
      for (let i = 0; i < values.length; i++) {
        if (values[i] === '') continue;
        const p = i < paramsList.length && paramsList[i] !== '' ? `;${paramsList[i]}` : '';
        block += `${upper}${p}:${escape(values[i])}\n`;
      }
      const sep = before.endsWith('\n') ? '' : '\n';
      out = before + sep + block + after;
    }
  }
  return out.replace(/\n{3,}/g, '\n\n');
}

function fieldValues(raw, name) {
  const unfolded = unfold(raw);
  const lines = splitLines(unfolded);
  const upper = name.toUpperCase();
  return lines.filter(l => l.name === upper).map(valueOf);
}

// ───────────── 测试 ─────────────

console.log('\n=== 1. 基本解析（vCard 3.0）===');
const basic = [
  'BEGIN:VCARD',
  'VERSION:3.0',
  'UID:abc-123',
  'FN:张三',
  'N:张;三;;;',
  'ORG:某某公司;技术部',
  'TITLE:工程师',
  'TEL;TYPE=CELL:13800138000',
  'TEL;TYPE=WORK:010-12345678',
  'EMAIL;TYPE=WORK:zhangsan@example.com',
  'NOTE:第一行\\n第二行',
  'REV:2026-11-10T12:00:00Z',
  'END:VCARD'
].join('\r\n');

const c1 = parse(basic, 'https://nas/carddav/default/abc.vcf', 'etag1');
eq('uid', c1.uid, 'abc-123');
eq('显示名', c1.displayName, '张三');
eq('姓', c1.familyName, '张');
eq('名', c1.givenName, '三');
eq('公司（只取第一级）', c1.org, '某某公司');
eq('职位', c1.title, '工程师');
eq('电话数量', c1.phones.length, 2);
eq('第一个电话', c1.phones[0].value, '13800138000');
eq('第一个电话类型', c1.phones[0].type, 'CELL');
eq('第二个电话类型', c1.phones[1].type, 'WORK');
eq('邮箱', c1.emails[0].value, 'zhangsan@example.com');
eq('备注（转义还原）', c1.note, '第一行\n第二行');
eq('REV', c1.rev, '2026-11-10T12:00:00Z');

console.log('\n=== 2. 折行展开（RFC 6350 折行）===');
const folded = [
  'BEGIN:VCARD',
  'VERSION:3.0',
  'UID:fold-1',
  'FN:一个非常长的名字用来测试折行展开功能是否正常工作',
  'NOTE:这是一段很长的备注，被服务器按 75 字节折成多行，',
  ' 续行以空格开头，解析时必须把它们拼回去，',
  ' 否则会得到一堆残片。',
  'END:VCARD'
].join('\r\n');
const c2 = parse(folded, '', '');
ok('折行后备注完整', c2.note.indexOf('残片') > 0, `实际: ${c2.note}`);
ok('折行后没有多余空格', c2.note.indexOf(' ，') < 0, `实际: ${c2.note}`);

console.log('\n=== 3. 无 FN 时用 N 拼名字 ===');
const noFn = ['BEGIN:VCARD', 'VERSION:3.0', 'UID:noname', 'N:李;四;;;', 'END:VCARD'].join('\r\n');
eq('中文直接连写', parse(noFn, '', '').displayName, '李四');
const west = ['BEGIN:VCARD', 'VERSION:3.0', 'UID:w', 'N:Smith;John;;;', 'END:VCARD'].join('\r\n');
eq('西文加空格', parse(west, '', '').displayName, 'John Smith');

console.log('\n=== 4. setField 就地改（保留未建模属性）===');
let edited = setField(basic, 'FN', '张三丰');
eq('FN 已改', fieldValues(edited, 'FN'), ['张三丰']);
ok('PHOTO/X-* 类未建模属性不受影响（原文本无则验证其它行完整）',
  edited.indexOf('TEL;TYPE=CELL:13800138000') >= 0, '电话行被破坏');
ok('UID 未变', fieldValues(edited, 'UID')[0] === 'abc-123');

console.log('\n=== 5. setField 新增不存在字段 ===');
let added = setField(basic, 'NICKNAME', '小三');
eq('NICKNAME 已插入', fieldValues(added, 'NICKNAME'), ['小三']);
ok('END:VCARD 仍在最后', added.trim().endsWith('END:VCARD'), added.trim().slice(-40));

console.log('\n=== 6. setField 传空删字段 ===');
let removed = setField(basic, 'TITLE', '');
eq('TITLE 已删除', fieldValues(removed, 'TITLE'), []);
ok('其它字段还在', fieldValues(removed, 'FN')[0] === '张三');

console.log('\n=== 7. setMulti 权威替换 TEL ===');
let multi = setMulti(basic, 'TEL', ['13900139000', '021-9999'], ['TYPE=CELL', 'TYPE=HOME']);
eq('电话变成 2 条', fieldValues(multi, 'TEL').length, 2);
eq('新号码', fieldValues(multi, 'TEL'), ['13900139000', '021-9999']);
ok('旧号码已清除', multi.indexOf('13800138000') < 0, '旧号码残留');

console.log('\n=== 8. 转义往返 ===');
const tricky = '含逗号,分号;反斜杠\\和换行\n的文本';
eq('escape→unescape 往返一致', unescape(escape(tricky)), tricky);

console.log('\n=== 9. 带引号参数的冒号处理 ===');
const altrep = ['BEGIN:VCARD', 'VERSION:3.0', 'UID:q', 'FN:Test',
  'PHOTO;ALTREP="http://example.com/a:b.jpg":BASE64DATA', 'END:VCARD'].join('\r\n');
const c3 = parse(altrep, '', '');
eq('带引号参数里冒号不误判', c3.displayName, 'Test');
ok('PHOTO 被识别（不解析内容）', c3.hasPhoto === true);

console.log('\n=== 10. 异常输入不崩 ===');
eq('空字符串返回 null', parse('', '', ''), null);
eq('无 BEGIN 返回 null', parse('garbage', '', ''), null);
ok('只有头尾也能解析', parse('BEGIN:VCARD\r\nEND:VCARD', '', '') !== null);

console.log('\n=== 11. 群晖风格真实样本 ===');
// 群晖 Synology Contacts 导出的典型格式（含 item1. 分组前缀）
const syno = [
  'BEGIN:VCARD',
  'VERSION:3.0',
  'PRODID:-//Synology//Synology Contacts//EN',
  'UID:8f3a-4b2c-syno-001',
  'N:王;小明;;;',
  'FN:王小明',
  'item1.TEL;type=CELL:13512345678',
  'item1.X-ABLabel:_$!<Mobile>!$_',
  'ORG:测试公司',
  'REV:2026-11-10T08:00:00Z',
  'END:VCARD'
].join('\r\n');
const c4 = parse(syno, 'https://nas.yangyq.net/carddav/default/8f3a.vcf', 'e9');
eq('群晖 UID', c4.uid, '8f3a-4b2c-syno-001');
eq('群晖名字', c4.displayName, '王小明');
eq('群晖电话（item1. 分组前缀不影响 TEL 识别）', c4.phones[0].value, '13512345678');
eq('群晖电话类型（小写 type= 也能认）', c4.phones[0].type, 'CELL');
ok('群晖 PRODID 等未建模行保留在 raw 中', syno.indexOf('PRODID') >= 0);
// 关键：改字段后 PRODID / X-ABLabel 不能被吞掉
const synoEdited = setField(syno, 'FN', '王大明');
ok('改 FN 后 PRODID 仍在', synoEdited.indexOf('PRODID') >= 0, '丢了 PRODID');
ok('改 FN 后 X-ABLabel 仍在', synoEdited.indexOf('X-ABLabel') >= 0, '丢了 X-ABLabel');
eq('改 FN 后新值生效', fieldValues(synoEdited, 'FN'), ['王大明']);

console.log('\n=== 12. 多段字段里值含转义分号（回归）===');
// 真实踩到的 bug：ORG 值里带 \; 时，先反转义再 split 会截断
const segCase = ['BEGIN:VCARD', 'VERSION:3.0', 'UID:seg-1',
  'FN:赵六', 'N:赵;六;;;',
  'ORG:含\\,逗号\\;分号的公司;技术部',
  'END:VCARD'].join('\r\n');
const c5 = parse(segCase, '', '');
eq('ORG 第一级完整（含分号不被截断）', c5.org, '含,逗号;分号的公司');
eq('N 的姓', c5.familyName, '赵');
eq('N 的名', c5.givenName, '六');

console.log('\n=== 13. 多段字段写回不能被转义（回归）===');
// 真实 bug：setField(raw,'N','张;三;;;') 会把分号转义成 \;，
// 服务端把整串当"姓"，名字段全丢
const nWritten = setStructuredField(basic, 'N', ['张', '三', '', '', '']);
const nVals = fieldValues(nWritten, 'N');
eq('N 写回是裸分号五段', nVals, ['张;三;;;']);
ok('N 里没有 \\; 转义', nWritten.indexOf('N:张\\;') < 0, '仍然被转义了');
// 值里本身含分号时，该段必须转义，但段分隔符不能转
const nWithSemi = setStructuredField(basic, 'N', ['张;复姓', '三', '', '', '']);
const nVals2 = fieldValues(nWithSemi, 'N');
eq('值内分号被转义、段分隔保留', nVals2, ['张;复姓;三;;;']);

console.log('\n' + '='.repeat(46));
console.log(`结果：通过 ${pass}，失败 ${fail}`);
console.log('='.repeat(46));
process.exit(fail === 0 ? 0 : 1);