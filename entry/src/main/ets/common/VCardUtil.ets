// entry/src/main/ets/common/VCardUtil.ets
// vCard 3.0 解析与序列化（RFC 2426 / RFC 6350 子集）
//
// 设计取舍（与 IcsUtil 保持一致）：
// - **不重建卡片，只在原文上改字段**：vCard 里有大量本应用不建模的属性
//   （X-ABLabel、item1.TEL、PHOTO、REV、PRODID 等），若按本地字段重建再 PUT，
//   等于把没存的属性全部删掉。所以"编辑"走「GET 原文 → 就地改 → PUT 回写」。
// - **只读解析到本地模型**：本地库只存需要的字段，用于列表展示与差异比对。
// - **行展开（unfolding）必须做**：vCard 规定长行折行，续行以空格或 TAB 开头。
//   不展开会把一个字段拆成两行，解析出一堆残片。
import { LogUtil } from './LogUtil';

/** 电话条目（含类型标签） */
export class VCardPhone {
  value: string = '';
  type: string = '';   // CELL / WORK / HOME / VOICE / 文本标签
}

/** 邮箱条目 */
export class VCardEmail {
  value: string = '';
  type: string = '';
}

/** 地址条目 */
export class VCardAddress {
  type: string = '';
  street: string = '';
  city: string = '';
  region: string = '';
  postcode: string = '';
  country: string = '';
}

/**
 * 解析后的联系人（本地模型）
 */
export class VCardContact {
  /** 完整原始 vCard 文本（PUT 回写用；编辑时在此基础上改） */
  raw: string = '';
  uid: string = '';
  /** 资源在服务器上的完整 URL */
  href: string = '';
  etag: string = '';
  /** 格式化后的显示名（FN 优先，缺失时由 N 拼） */
  displayName: string = '';
  /** 结构化姓名 */
  familyName: string = '';
  givenName: string = '';
  middleName: string = '';
  prefix: string = '';
  suffix: string = '';
  org: string = '';
  title: string = '';
  nickname: string = '';
  note: string = '';
  phones: VCardPhone[] = [];
  emails: VCardEmail[] = [];
  addresses: VCardAddress[] = [];
  /** 头像等大字段不解析，只记录是否存在，避免占内存 */
  hasPhoto: boolean = false;
  /** 修订时间（REV），用于冲突判断；缺失为空 */
  rev: string = '';
  /** 所属地址簿 URL */
  bookHref: string = '';
}

/**
 * 一个"逻辑行"：属性名 + 参数串 + 值 + 在原文中的行区间。
 * 用于"就地改字段"时精确定位替换范围，而不重建整张卡片。
 */
class VLine {
  /** 折叠展开后的逻辑行文本 */
  text: string = '';
  /** 在展开后字符串里的起始偏移 */
  start: number = 0;
  /** 在展开后字符串里的结束偏移（不含换行） */
  end: number = 0;
  /** 属性名（大写，含 group 前缀时如 item1.TEL 去掉 group 只留 TEL） */
  name: string = '';
  /** group 前缀（如 item1），无则为空 */
  group: string = '';
}

export class VCardUtil {
  /** 单个字段值上限，防御异常大字段导致的内存问题 */
  private static readonly MAX_FIELD_LEN: number = 20000;

  /**
   * 展开折行：把 "续行以空格/TAB 开头" 的物理行合并为逻辑行。
   * 返回展开后的文本（用 \n 分隔），并保留与原文的偏移映射交给 splitLines 处理。
   */
  static unfold(text: string): string {
    // 统一换行符：远端可能给 CRLF / CR / LF
    const normalized: string = text.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
    const physical: string[] = normalized.split('\n');
    const out: string[] = [];
    for (const line of physical) {
      if (line.length > 0 && (line.charAt(0) === ' ' || line.charAt(0) === '\t')) {
        // 续行：接到上一行末尾（去掉开头那一个空白字符）
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

  /**
   * 折行：按 RFC 6350 每 75 字节折一行，续行以单个空格开头。
   * ⚠️ 按**字节**折而不是按字符 —— 中文 UTF-8 占 3 字节，
   * 按字符折会让实际字节数超标，部分服务器会拒收。
   */
  static fold(text: string): string {
    const lines: string[] = text.replace(/\r\n/g, '\n').replace(/\r/g, '\n').split('\n');
    const out: string[] = [];
    for (const line of lines) {
      if (line.length === 0) {
        out.push('');
        continue;
      }
      let chunk: string = '';
      let chunkBytes: number = 0;
      let first: boolean = true;
      // 逐字符累加，超过 75 字节就断开（续行首部要留 1 字节给空格）
      for (let i = 0; i < line.length; i++) {
        const ch: string = line.charAt(i);
        const b: number = VCardUtil.utf8Len(ch);
        const limit: number = first ? 75 : 74;
        if (chunkBytes + b > limit && chunk.length > 0) {
          out.push(first ? chunk : ' ' + chunk);
          first = false;
          chunk = '';
          chunkBytes = 0;
        }
        chunk += ch;
        chunkBytes += b;
      }
      if (chunk.length > 0) {
        out.push(first ? chunk : ' ' + chunk);
      }
    }
    return out.join('\r\n');
  }

  /** 单个字符的 UTF-8 字节数 */
  private static utf8Len(ch: string): number {
    const code: number = ch.charCodeAt(0);
    if (code < 0x80) {
      return 1;
    }
    if (code < 0x800) {
      return 2;
    }
    // 代理对（emoji 等）算 4 字节，高位代理单独出现时按 3 处理
    if (code >= 0xD800 && code <= 0xDBFF) {
      return 4;
    }
    if (code >= 0xDC00 && code <= 0xDFFF) {
      return 0; // 与前面的高位代理合并计过，不重复累加
    }
    return 3;
  }

  /** 把展开后的文本切成带偏移的逻辑行 */
  private static splitLines(unfolded: string): VLine[] {
    const out: VLine[] = [];
    let offset: number = 0;
    const parts: string[] = unfolded.split('\n');
    for (const text of parts) {
      const line = new VLine();
      line.text = text;
      line.start = offset;
      line.end = offset + text.length;
      offset = line.end + 1; // +1 为换行
      // 解析 "group.NAME;PARAM=..;PARAM:x" 中的 NAME 与 group
      const head: string = text;
      const colon: number = VCardUtil.findValueColon(head);
      const meta: string = colon >= 0 ? head.substring(0, colon) : head;
      let namePart: string = meta.split(';')[0];
      const dot: number = namePart.indexOf('.');
      if (dot > 0) {
        line.group = namePart.substring(0, dot);
        namePart = namePart.substring(dot + 1);
      }
      line.name = namePart.trim().toUpperCase();
      out.push(line);
    }
    return out;
  }

  /**
   * 找到"值分隔冒号"的位置。
   * 不能简单用 indexOf(':')：参数里可能有引号包裹的冒号，
   * 也可能有 URL 类型的参数值（如 ALTREP="http://..."）。这里跳过引号内内容。
   */
  private static findValueColon(line: string): number {
    let inQuote: boolean = false;
    for (let i = 0; i < line.length; i++) {
      const c: string = line.charAt(i);
      if (c === '"') {
        inQuote = !inQuote;
        continue;
      }
      if (c === ':' && !inQuote) {
        return i;
      }
    }
    return -1;
  }

  /** 取某行的原始值（冒号之后部分，已去引号转义） */
  private static valueOf(line: VLine): string {
    const colon: number = VCardUtil.findValueColon(line.text);
    if (colon < 0) {
      return '';
    }
    let v: string = line.text.substring(colon + 1);
    if (v.length > VCardUtil.MAX_FIELD_LEN) {
      v = v.substring(0, VCardUtil.MAX_FIELD_LEN);
    }
    return VCardUtil.unescape(v);
  }

  /**
   * 取某行的**原始值**（冒号之后，**不反转义**）。
   *
   * 🔴 为什么需要单独一个（2026-11-11 实测踩到）：
   *   多段字段（N / ORG / ADR）内部用 `;` 分段，而值里的分号是用 `\;` 转义的。
   *   若先反转义再 `split(';')`，会把**本属于值一部分的分号**当成段分隔符：
   *       原值：含\,逗号\;分号的公司
   *       反转义后：含,逗号;分号的公司
   *       split(';')[0] → "含,逗号"      ← 后半截被丢了
   *   正确顺序是：**先按未转义的分号拆段，再逐段反转义**。
   */
  private static rawValueOf(line: VLine): string {
    const colon: number = VCardUtil.findValueColon(line.text);
    if (colon < 0) {
      return '';
    }
    const v: string = line.text.substring(colon + 1);
    return v.length > VCardUtil.MAX_FIELD_LEN ? v.substring(0, VCardUtil.MAX_FIELD_LEN) : v;
  }

  /**
   * 按**未转义的**分号拆段：`a;b\;c;d` → ["a", "b;c", "d"]
   * 拆完每段都做反转义。
   */
  private static splitSegments(raw: string): string[] {
    const out: string[] = [];
    let cur: string = '';
    for (let i = 0; i < raw.length; i++) {
      const ch: string = raw.charAt(i);
      if (ch === '\\' && i + 1 < raw.length) {
        // 转义序列整段保留，交给 unescape 处理
        cur += ch + raw.charAt(i + 1);
        i++;
      } else if (ch === ';') {
        out.push(VCardUtil.unescape(cur));
        cur = '';
      } else {
        cur += ch;
      }
    }
    out.push(VCardUtil.unescape(cur));
    return out;
  }

  /** 取参数串（冒号之前、名之后） */
  private static paramsOf(line: VLine): string {
    const colon: number = VCardUtil.findValueColon(line.text);
    const meta: string = colon >= 0 ? line.text.substring(0, colon) : line.text;
    const parts: string[] = meta.split(';');
    parts.shift(); // 去掉属性名
    return parts.join(';');
  }

  /**
   * 转义还原：vCard 值里 `\\` `\,` `\;` `\n` 是转义序列。
   */
  static unescape(v: string): string {
    if (v.indexOf('\\') < 0) {
      return v;
    }
    let out: string = '';
    for (let i = 0; i < v.length; i++) {
      const c: string = v.charAt(i);
      if (c === '\\' && i + 1 < v.length) {
        const n: string = v.charAt(i + 1);
        if (n === 'n' || n === 'N') {
          out += '\n';
        } else if (n === ',' || n === ';' || n === '\\') {
          out += n;
        } else {
          out += n;
        }
        i++;
      } else {
        out += c;
      }
    }
    return out;
  }

  /** 转义：写回远端时用 */
  static escape(v: string): string {
    return v.replace(/\\/g, '\\\\')
      .replace(/\n/g, '\\n')
      .replace(/\r/g, '')
      .replace(/,/g, '\\,')
      .replace(/;/g, '\\;');
  }

  /**
   * 解析单个 vCard 文本 → 本地模型。
   * 失败不抛错（远端脏数据不该让整个同步崩），返回 null 由调用方跳过并计数。
   */
  static parse(raw: string, href: string = '', etag: string = ''): VCardContact | null {
    if (raw === '' || raw.indexOf('BEGIN:VCARD') < 0) {
      return null;
    }
    const c = new VCardContact();
    c.raw = raw;
    c.href = href;
    c.etag = etag;

    const unfolded: string = VCardUtil.unfold(raw);
    const lines: VLine[] = VCardUtil.splitLines(unfolded);

    let fn: string = '';
    let n: string = '';
    // 保存 N 的原始行引用：后面拆五段时要用未转义原文
    let nLine: VLine | null = null;
    for (const line of lines) {
      switch (line.name) {
        case 'UID':
          c.uid = VCardUtil.valueOf(line);
          break;
        case 'FN':
          if (fn === '') {
            fn = VCardUtil.valueOf(line);
          }
          break;
        case 'N':
          if (n === '') {
            n = VCardUtil.valueOf(line);
            nLine = line;
          }
          break;
        case 'ORG':
          if (c.org === '') {
            // ORG 可多级，用 ; 分隔，取第一级作公司名。
            // 必须用 splitSegments（按未转义分号拆），否则值里带 \; 会被截断。
            const segs: string[] = VCardUtil.splitSegments(VCardUtil.rawValueOf(line));
            c.org = segs.length > 0 ? segs[0] : '';
          }
          break;
        case 'TITLE':
          c.title = VCardUtil.valueOf(line);
          break;
        case 'NICKNAME':
          c.nickname = VCardUtil.valueOf(line).split(',')[0];
          break;
        case 'NOTE':
          c.note = VCardUtil.valueOf(line);
          break;
        case 'REV':
          c.rev = VCardUtil.valueOf(line);
          break;
        case 'PHOTO':
          c.hasPhoto = true;
          break;
        case 'TEL': {
          const p = new VCardPhone();
          p.value = VCardUtil.valueOf(line);
          p.type = VCardUtil.firstType(VCardUtil.paramsOf(line));
          if (p.value !== '') {
            c.phones.push(p);
          }
          break;
        }
        case 'EMAIL': {
          const e = new VCardEmail();
          e.value = VCardUtil.valueOf(line);
          e.type = VCardUtil.firstType(VCardUtil.paramsOf(line));
          if (e.value !== '') {
            c.emails.push(e);
          }
          break;
        }
        case 'ADR': {
          const a = VCardUtil.parseAddress(VCardUtil.rawValueOf(line), VCardUtil.paramsOf(line));
          if (a !== null) {
            c.addresses.push(a);
          }
          break;
        }
        default:
          break;
      }
    }

    // 拆 N（family;given;middle;prefix;suffix）
    // ⚠️ n 已经过 valueOf 反转义，这里不能再按 ; 拆（姓氏里可能有 \;）
    //    所以从原始行重新取一遍
    if (n !== '') {
      const seg: string[] = nLine !== null
        ? VCardUtil.splitSegments(VCardUtil.rawValueOf(nLine)) : n.split(';');
      c.familyName = seg.length > 0 ? seg[0] : '';
      c.givenName = seg.length > 1 ? seg[1] : '';
      c.middleName = seg.length > 2 ? seg[2] : '';
      c.prefix = seg.length > 3 ? seg[3] : '';
      c.suffix = seg.length > 4 ? seg[4] : '';
    }

    // 显示名：FN → N 拼装 → UID 兜底
    if (fn !== '') {
      c.displayName = fn;
    } else if (c.familyName !== '' || c.givenName !== '') {
      c.displayName = VCardUtil.joinName(c.givenName, c.familyName);
    } else if (c.org !== '') {
      c.displayName = c.org;
    } else if (c.uid !== '') {
      c.displayName = c.uid;
    } else {
      c.displayName = '(未命名)';
    }
    if (c.uid === '') {
      // UID 缺失的联系人无法稳定比对，用 href 末段兜底（服务端通常以 UID 命名资源）
      c.uid = VCardUtil.resourceName(href);
    }
    return c;
  }

  /** 取参数里的第一个类型值（TYPE=CELL / CELL / TYPE="WORK,VOICE"） */
  private static firstType(params: string): string {
    if (params === '') {
      return '';
    }
    const segs: string[] = params.split(';');
    for (const seg of segs) {
      const t: string = seg.trim();
      const eq: number = t.indexOf('=');
      if (eq > 0) {
        const key: string = t.substring(0, eq).toUpperCase();
        if (key === 'TYPE') {
          let val: string = t.substring(eq + 1).replace(/"/g, '');
          if (val.indexOf(',') > 0) {
            val = val.split(',')[0];
          }
          return val.trim().toUpperCase();
        }
      } else if (t !== '' && t.indexOf('=') < 0 && t.toUpperCase() !== 'PREF') {
        // 3.0 简写：TEL;CELL:... / TEL;TYPE=CELL:...
        return t.toUpperCase();
      }
    }
    return '';
  }

  /** 解析 ADR 的 7 段：PO;EXT;STREET;CITY;REGION;POSTCODE;COUNTRY */
  private static parseAddress(value: string, params: string): VCardAddress | null {
    if (value === '') {
      return null;
    }
    // ⚠️ 传进来的是**未转义**原文，仍要用 splitSegments 免得值内分号被误拆
    const seg: string[] = VCardUtil.splitSegments(value);
    const a = new VCardAddress();
    a.type = VCardUtil.firstType(params);
    a.street = seg.length > 2 ? seg[2] : '';
    a.city = seg.length > 3 ? seg[3] : '';
    a.region = seg.length > 4 ? seg[4] : '';
    a.postcode = seg.length > 5 ? seg[5] : '';
    a.country = seg.length > 6 ? seg[6] : '';
    // 全空则视为无效地址
    if (a.street === '' && a.city === '' && a.region === '' && a.postcode === '' && a.country === '') {
      return null;
    }
    return a;
  }

  /** 拼显示名：中文习惯「姓+名」直接相连，西文习惯留空格 */
  static joinName(given: string, family: string): string {
    if (given === '') {
      return family;
    }
    if (family === '') {
      return given;
    }
    // 含中文则直接连写
    const hasCJK: boolean = /[\u4e00-\u9fff]/.test(given + family);
    return hasCJK ? family + given : `${given} ${family}`;
  }

  /** 从 href 取资源名（去扩展名） */
  static resourceName(href: string): string {
    if (href === '') {
      return '';
    }
    const noQuery: string = href.split('?')[0];
    const segs: string[] = noQuery.split('/').filter((s: string): boolean => s !== '');
    if (segs.length === 0) {
      return '';
    }
    let last: string = segs[segs.length - 1];
    try {
      last = decodeURIComponent(last);
    } catch (err) {
      // 保持原样
    }
    return last.replace(/\.vcf$/i, '');
  }

  /**
   * ⭐ 就地改字段：在**原文**上替换/插入单个属性行，其余内容（含未建模的 X-*、PHOTO、
   * item1.* 分组）原样保留。这是 PUT 回写的核心，避免"重建卡片丢字段"。
   *
   * @param raw      原始 vCard 文本
   * @param name     属性名（如 FN / TEL / NOTE），全大写
   * @param newValue 新值；传空字符串表示删除该属性行
   * @param params   可选的属性参数（如 'TYPE=CELL'），仅在插入时使用
   */
  static setField(raw: string, name: string, newValue: string, params: string = ''): string {
    const unfolded: string = VCardUtil.unfold(raw);
    const lines: VLine[] = VCardUtil.splitLines(unfolded);
    const upper: string = name.toUpperCase();

    // 找出该属性的所有行（可能有多行，如多个 TEL）
    const hits: VLine[] = lines.filter((l: VLine): boolean => l.name === upper);

    const lineText: string = params === ''
      ? `${upper}:${VCardUtil.escape(newValue)}`
      : `${upper};${params}:${VCardUtil.escape(newValue)}`;

    // 情形一：替换第一个，删除其余（单值属性语义）
    if (hits.length > 0) {
      let out: string = '';
      let cursor: number = 0;
      for (let i = 0; i < hits.length; i++) {
        const h: VLine = hits[i];
        out += unfolded.substring(cursor, h.start);
        if (i === 0 && newValue !== '') {
          // 🔴 必须补换行：cursor 会跳过后面的换行符，不补的话新值会和下一行粘在一起
          //    （2026-11-10 实测踩到：FN 改完变成 "张三丰N:张;三;;;"）
          out += lineText + '\n';
        }
        // newValue 为空 → 不写任何东西，等于删掉这一行
        cursor = h.end;
        // 连同该行后的换行一起跳过
        if (cursor < unfolded.length && unfolded.charAt(cursor) === '\n') {
          cursor += 1;
        }
      }
      out += unfolded.substring(cursor);
      return VCardUtil.tidyNewlines(out);
    }

    // 情形二：原文没有该属性 → 插到 END:VCARD 之前
    if (newValue === '') {
      return raw; // 本来就没有，无需删除
    }
    const endIdx: number = unfolded.lastIndexOf('END:VCARD');
    if (endIdx < 0) {
      return raw;
    }
    const before: string = unfolded.substring(0, endIdx);
    const after: string = unfolded.substring(endIdx);
    const sep: string = before.endsWith('\n') ? '' : '\n';
    return VCardUtil.tidyNewlines(before + sep + lineText + '\n' + after);
  }

  /**
   * 批量设置 TEL / EMAIL / ADR 这类多值属性。
   * 语义＝**权威替换**：先删掉该类所有行，再按传入顺序写入。
   * （与 CalDAV 侧 PUT 的"权威替换"语义保持一致，避免本地删除的电话在远端残留）
   */
  static setMulti(raw: string, name: string, values: string[], paramsList: string[]): string {
    const unfolded: string = VCardUtil.unfold(raw);
    const lines: VLine[] = VCardUtil.splitLines(unfolded);
    const upper: string = name.toUpperCase();
    const hits: VLine[] = lines.filter((l: VLine): boolean => l.name === upper);

    let out: string = '';
    let cursor: number = 0;
    // 先在第一条命中处写入全部新行，其余命中行删掉
    let written: boolean = false;
    for (const h of hits) {
      out += unfolded.substring(cursor, h.start);
      if (!written) {
        for (let i = 0; i < values.length; i++) {
          if (values[i] === '') {
            continue;
          }
          const p: string = i < paramsList.length && paramsList[i] !== '' ? `;${paramsList[i]}` : '';
          out += `${upper}${p}:${VCardUtil.escape(values[i])}\n`;
        }
        written = true;
      }
      cursor = h.end;
      if (cursor < unfolded.length && unfolded.charAt(cursor) === '\n') {
        cursor += 1;
      }
    }
    out += unfolded.substring(cursor);

    if (!written && values.length > 0) {
      // 原来没有 → 插到 END:VCARD 前
      const endIdx: number = out.lastIndexOf('END:VCARD');
      if (endIdx >= 0) {
        const before: string = out.substring(0, endIdx);
        const after: string = out.substring(endIdx);
        let block: string = '';
        for (let i = 0; i < values.length; i++) {
          if (values[i] === '') {
            continue;
          }
          const p: string = i < paramsList.length && paramsList[i] !== '' ? `;${paramsList[i]}` : '';
          block += `${upper}${p}:${VCardUtil.escape(values[i])}\n`;
        }
        const sep: string = before.endsWith('\n') ? '' : '\n';
        out = before + sep + block + after;
      }
    }
    return VCardUtil.tidyNewlines(out);
  }

  /** 去掉因删除行产生的连续空行 */
  private static tidyNewlines(s: string): string {
    return s.replace(/\n{3,}/g, '\n\n');
  }

  /** 取某个属性在原文中的所有值（用于校验与调试） */
  static fieldValues(raw: string, name: string): string[] {
    const unfolded: string = VCardUtil.unfold(raw);
    const lines: VLine[] = VCardUtil.splitLines(unfolded);
    const upper: string = name.toUpperCase();
    const out: string[] = [];
    for (const l of lines) {
      if (l.name === upper) {
        out.push(VCardUtil.valueOf(l));
      }
    }
    return out;
  }

  /**
   * 用本地模型生成一张**全新** vCard 3.0 文本（仅用于"本应用内新建联系人"）。
   * 已有联系人的编辑一律走 setField / setMulti 就地改，不走这里。
   */
  static build(c: VCardContact, uid: string): string {
    const now: string = VCardUtil.utcStamp();
    const lines: string[] = [];
    lines.push('BEGIN:VCARD');
    lines.push('VERSION:3.0');
    lines.push(`UID:${VCardUtil.escape(uid)}`);
    lines.push(`FN:${VCardUtil.escape(c.displayName)}`);
    const n: string = `${VCardUtil.escape(c.familyName)};${VCardUtil.escape(c.givenName)};`
      + `${VCardUtil.escape(c.middleName)};${VCardUtil.escape(c.prefix)};${VCardUtil.escape(c.suffix)}`;
    lines.push(`N:${n}`);
    if (c.org !== '') {
      lines.push(`ORG:${VCardUtil.escape(c.org)}`);
    }
    if (c.title !== '') {
      lines.push(`TITLE:${VCardUtil.escape(c.title)}`);
    }
    if (c.nickname !== '') {
      lines.push(`NICKNAME:${VCardUtil.escape(c.nickname)}`);
    }
    for (const p of c.phones) {
      lines.push(`TEL${p.type !== '' ? ';TYPE=' + p.type : ''}:${VCardUtil.escape(p.value)}`);
    }
    for (const e of c.emails) {
      lines.push(`EMAIL${e.type !== '' ? ';TYPE=' + e.type : ''};TYPE=INTERNET:${VCardUtil.escape(e.value)}`);
    }
    for (const a of c.addresses) {
      const adr: string = `;;${VCardUtil.escape(a.street)};${VCardUtil.escape(a.city)};`
        + `${VCardUtil.escape(a.region)};${VCardUtil.escape(a.postcode)};${VCardUtil.escape(a.country)}`;
      lines.push(`ADR${a.type !== '' ? ';TYPE=' + a.type : ''}:${adr}`);
    }
    if (c.note !== '') {
      lines.push(`NOTE:${VCardUtil.escape(c.note)}`);
    }
    lines.push(`REV:${now}`);
    lines.push('END:VCARD');
    return VCardUtil.fold(lines.join('\r\n'));
  }

  /** 生成 REV 时间戳：2026-11-10T12:00:00Z */
  static utcStamp(): string {
    const d = new Date();
    const p = (n: number): string => n < 10 ? '0' + n : String(n);
    return `${d.getUTCFullYear()}-${p(d.getUTCMonth() + 1)}-${p(d.getUTCDate())}`
      + `T${p(d.getUTCHours())}:${p(d.getUTCMinutes())}:${p(d.getUTCSeconds())}Z`;
  }

  /** 取姓名首字母/首字（列表头像占位用） */
  static initial(c: VCardContact): string {
    const name: string = c.displayName.trim();
    if (name === '') {
      return '#';
    }
    const first: string = name.charAt(0);
    // 中文取首字，西文取首字母大写
    if (/[\u4e00-\u9fff]/.test(first)) {
      return first;
    }
    return first.toUpperCase();
  }

  /** 摘要日志：不打印具体电话/邮箱（隐私），只打结构与数量 */
  static summary(c: VCardContact): string {
    return `「${c.displayName}」tel=${c.phones.length} email=${c.emails.length} `
      + `adr=${c.addresses.length} uid=${c.uid === '' ? '(空)' : 'ok'} photo=${c.hasPhoto}`;
  }
}