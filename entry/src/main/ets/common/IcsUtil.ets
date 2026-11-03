// entry/src/main/ets/common/IcsUtil.ets
// iCalendar 解析与生成
import { LocalEvent, RemoteEvent } from './EventDb';

/** 解析出的远端日程（内部中间结构） */
class ParsedEvent {
  uid: string = '';
  title: string = '';
  description: string = '';
  location: string = '';
  startTime: number = 0;
  endTime: number = 0;
  isAllDay: boolean = false;
  recurring: boolean = false;
  duration: number = 0;   // DURATION 属性（毫秒），无 DTEND 时使用
  inAlarm: boolean = false; // 是否处于 VALARM 子组件内（内部属性不参与解析）
  rrule: string = '';       // 原始 RRULE 值
  exdates: string[] = [];   // 原始 EXDATE 值列表
  recurrenceId: number = 0; // 原始 RECURRENCE-ID（毫秒）——本行覆盖的是主事件的哪一次发生
  reminder: number = 0;     // 主提醒提前分钟数（第一个 VALARM，0 = 不提醒）
  reminders: number[] = []; // 全部提醒提前分钟数（多 VALARM）
}

/** iCal 时间解析结果 */
export class IcsTime {
  time: number = 0;
  allDay: boolean = false;
}

export class IcsUtil {
  /** 解析 VCALENDAR 文本为事件列表 */
  static parse(ics: string): RemoteEvent[] {
    const unfolded: string = ics.replace(/\r?\n[ \t]/g, '');
    const lines: string[] = unfolded.split(/\r?\n/);
    const parsed: ParsedEvent[] = [];
    let current: ParsedEvent | null = null;
    for (const line of lines) {
      const upper: string = line.toUpperCase();
      if (upper.startsWith('BEGIN:VEVENT')) {
        current = new ParsedEvent();
        continue;
      }
      if (upper.startsWith('END:VEVENT')) {
        if (current !== null && current.startTime > 0) {
          // 无 DTEND 时用 DURATION；都没有则视为零长事件（不再丢弃整条）
          if (current.endTime < current.startTime) {
            current.endTime = current.duration > 0
              ? current.startTime + current.duration
              : current.startTime;
          }
          parsed.push(current);
        }
        current = null;
        continue;
      }
      if (current === null) {
        continue;
      }
      // 跳过 VALARM 闹钟子组件，避免其 DESCRIPTION 等属性污染事件
      if (upper.startsWith('BEGIN:VALARM')) {
        current.inAlarm = true;
        continue;
      }
      if (upper.startsWith('END:VALARM')) {
        current.inAlarm = false;
        continue;
      }
      if (current.inAlarm) {
        // VALARM 内部：捕获 TRIGGER 提醒提前量（如 -PT10M = 提前 10 分钟）
        const ac: number = line.indexOf(':');
        if (ac > 0) {
          const ap: string = line.substring(0, ac);
          const av: string = line.substring(ac + 1).trim();
          const an: string = ap.split(';')[0].toUpperCase();
          if (an === 'TRIGGER') {
            const m: number = IcsUtil.triggerMinutes(av, ap);
            if (m > 0) {
              current.reminders.push(m);
              if (current.reminder === 0) {
                current.reminder = m; // 第一个提醒作为主提醒（兼容旧字段）
              }
            }
          }
        }
        continue;
      }
      const colon: number = line.indexOf(':');
      if (colon <= 0) {
        continue;
      }
      const propPart: string = line.substring(0, colon);
      const value: string = line.substring(colon + 1).trim();
      const propName: string = propPart.split(';')[0].toUpperCase();
      if (propName === 'UID') {
        current.uid = value;
      } else if (propName === 'SUMMARY') {
        current.title = IcsUtil.unescape(value);
      } else if (propName === 'DESCRIPTION') {
        current.description = IcsUtil.unescape(value);
      } else if (propName === 'LOCATION') {
        current.location = IcsUtil.unescape(value);
      } else if (propName === 'RRULE' || propName === 'RECURRENCE-ID') {
        current.recurring = true;
        if (propName === 'RRULE') {
          current.rrule = value;
        } else {
          // ⭐ 必须**保留 RECURRENCE-ID 的值**：它指出本行覆盖的是主事件哪一次发生。
          //    覆盖行的 DTSTART 是"被改到的新时间"，只改标题时两者才相同；
          //    一旦把某次发生改期，用 startTime 排除主事件那次发生就会漏掉 →
          //    App 与系统日历里同一日程出现两条（2026-09-19 真机事故）。
          const recDateOnly: boolean = propPart.toUpperCase().includes('VALUE=DATE');
          const rt = IcsUtil.parseTime(value, recDateOnly);
          if (rt !== null) {
            current.recurrenceId = rt.time;
          }
        }
      } else if (propName === 'EXDATE') {
        const exValues: string[] = value.split(',');
        for (const ex of exValues) {
          if (ex.trim() !== '') {
            current.exdates.push(ex.trim());
          }
        }
      } else if (propName === 'DURATION') {
        current.duration = IcsUtil.parseDurationMs(value);
      } else if (propName === 'DTSTART') {
        const isDateOnly: boolean = propPart.toUpperCase().includes('VALUE=DATE');
        const t = IcsUtil.parseTime(value, isDateOnly);
        if (t !== null) {
          current.startTime = t.time;
          current.isAllDay = t.allDay;
        }
      } else if (propName === 'DTEND') {
        const isDateOnly: boolean = propPart.toUpperCase().includes('VALUE=DATE');
        const t = IcsUtil.parseTime(value, isDateOnly);
        if (t !== null) {
          // 全天日程 DTEND 为排他日期，减 1 秒存储为闭区间结束
          current.endTime = t.allDay ? t.time - 1000 : t.time;
        }
      }
    }
    return parsed.map((p: ParsedEvent): RemoteEvent => {
      const r = new RemoteEvent();
      r.uid = p.uid;
      r.title = p.title;
      r.description = p.description;
      r.location = p.location;
      r.startTime = p.startTime;
      r.endTime = p.endTime;
      r.isAllDay = p.isAllDay;
      r.recurring = p.recurring;
      r.rrule = p.rrule;
      r.exdate = p.exdates.join(';');
      r.recurrenceId = p.recurrenceId;
      r.reminder = p.reminder;
      r.reminders = p.reminders;
      return r;
    });
  }

  /** VALARM TRIGGER → 提前分钟数（负时长=提前）；绝对时间触发暂不支持 */
  private static triggerMinutes(value: string, propPart: string): number {
    if (propPart.toUpperCase().includes('VALUE=DATE-TIME')) {
      return 0;
    }
    const dur: number = IcsUtil.parseDurationMs(value);
    if (dur < 0) {
      return Math.min(1440, Math.round(-dur / 60000));
    }
    return 0;
  }

  /**
   * ⭐ 在**服务器原文**上改写某个 VTODO 的完成状态，返回新的整份 ICS。
   *
   * 为什么不从本地字段重建：VTODO 上还有 SUMMARY / DESCRIPTION / DUE / PRIORITY /
   * CATEGORIES / X-* 等大量字段，本地库只保存了其中少数几个。
   * 若按本地字段重新拼一份 VTODO 再 PUT，等于**把没保存的字段全部删掉**（丢用户数据）。
   * 因此这里只做"在原文上精确改那几行"，其余内容原样保留。
   *
   * 改动范围（按 RFC 5545，三者要一起维护，否则各客户端显示不一致）：
   *   - `STATUS:COMPLETED` ⇄ `STATUS:NEEDS-ACTION`
   *   - `COMPLETED:<UTC时间>`（完成时写入，取消完成时删除）
   *   - `PERCENT-COMPLETE:100` ⇄ `PERCENT-COMPLETE:0`
   *
   * @param ics      服务器上的原始 .ics 全文
   * @param uid      目标待办的 UID（一个资源里理论上只有一个 VTODO，但仍按 uid 定位更稳）
   * @param done     true=标记完成；false=取消完成
   * @returns        改写后的完整 ICS（调用方直接 PUT）
   */
  static rewriteTodoCompletion(ics: string, uid: string, done: boolean): string {
    const crlf: string = '\r\n';
    // 折行还原（RFC 5545 允许续行，续行以空格/Tab 开头）
    const unfolded: string = ics.replace(/\r?\n[ \t]/g, '');
    const lines: string[] = unfolded.split(/\r?\n/).map((s: string): string => s.replace(/\r$/, ''));
    const upperOf = (s: string): string => s.toUpperCase();
    const nowUtc: string = IcsUtil.fmtUtcNow();

    // ---------- 第 1 遍：找出"含目标 uid 的 VTODO"的 [begin, end] 行号区间 ----------
    // 必须两遍：RFC 5545 不规定字段顺序，UID 可能出现在 STATUS 之后。
    // 单遍实现会漏改（实测风险：STATUS 在前时 matched 仍为 false → 用户点了没反应）。
    let targetBegin: number = -1;
    let targetEnd: number = -1;
    let targetOrdinal: number = -1; // 目标 VTODO 是第几个块（0 基），供插入段按结构定位
    let curBegin: number = -1;
    let curHasUid: boolean = false;
    let blockIdx: number = -1;
    for (let i = 0; i < lines.length; i++) {
      const u: string = upperOf(lines[i]);
      if (u.startsWith('BEGIN:VTODO')) {
        blockIdx++;
        curBegin = i;
        curHasUid = false;
        continue;
      }
      if (u.startsWith('UID:') && curBegin >= 0) {
        if (lines[i].substring(4).trim() === uid) {
          curHasUid = true;
        }
        continue;
      }
      if (u.startsWith('END:VTODO')) {
        if (curBegin >= 0 && curHasUid && targetBegin < 0) {
          targetBegin = curBegin;
          targetEnd = i;
          targetOrdinal = blockIdx;
        }
        curBegin = -1;
        curHasUid = false;
      }
    }
    if (targetBegin < 0) {
      // 找不到目标 uid：原样返回（调用方会 PUT 回去，内容未变，等于无操作）
      return ics;
    }

    // ---------- 第 2 遍：在区间内改写状态字段 ----------
    const out: string[] = [];
    let sawStatus: boolean = false;
    let sawPercent: boolean = false;
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i];
      const u: string = upperOf(line);
      const inTarget: boolean = i > targetBegin && i < targetEnd;

      if (!inTarget) {
        out.push(line);
        continue;
      }
      if (u.startsWith('STATUS:')) {
        sawStatus = true;
        out.push(done ? 'STATUS:COMPLETED' : 'STATUS:NEEDS-ACTION');
        continue;
      }
      if (u.startsWith('COMPLETED')) {
        continue; // 丢弃旧的，完成时下面统一补
      }
      if (u.startsWith('PERCENT-COMPLETE')) {
        sawPercent = true;
        out.push(done ? 'PERCENT-COMPLETE:100' : 'PERCENT-COMPLETE:0');
        continue;
      }
      out.push(line);
    }

    // 缺字段则在目标 VTODO 的 END 之前补齐（有的客户端缺 STATUS 就不显示完成态）
    const extra: string[] = [];
    if (!sawStatus) {
      extra.push(done ? 'STATUS:COMPLETED' : 'STATUS:NEEDS-ACTION');
    }
    if (done) {
      extra.push('COMPLETED:' + nowUtc);
    }
    if (!sawPercent) {
      extra.push(done ? 'PERCENT-COMPLETE:100' : 'PERCENT-COMPLETE:0');
    }
    if (extra.length === 0) {
      const plain: string = out.join(crlf);
      return plain.endsWith(crlf) ? plain : plain + crlf;
    }

    // ⭐ 插入点必须按"结构"定位，不能按行号：
    //    改动可能删掉了旧的 COMPLETED 行，out 与第一遍的 lines 行号已不对齐，
    //    用行号定位会把字段写到 END:VTODO 之外（实测会落到 END:VCALENDAR 之后，
    //    结构非法，部分服务端直接 400）。
    //    这里重新数 VTODO 块，找到"第 targetOrdinal 个"块的 END 行插进去。
    const result: string[] = [];
    let vtodoIdx: number = -1;   // 当前处于第几个 VTODO 块内（-1=不在块内）
    let inserted: boolean = false;
    for (let i = 0; i < out.length; i++) {
      const u: string = upperOf(out[i]);
      if (u.startsWith('BEGIN:VTODO')) {
        vtodoIdx++;
        result.push(out[i]);
        continue;
      }
      if (u.startsWith('END:VTODO')) {
        // 走到目标块的 END 之前先补字段
        if (!inserted && vtodoIdx === targetOrdinal) {
          for (const ex of extra) {
            result.push(ex);
          }
          inserted = true;
        }
        // ⚠️ 不要重置 vtodoIdx：它是全局块序号，重置会让下一块从 0 重新数，
        //    多 VTODO 文件里永远匹配不到 targetOrdinal（静默失败）。
        result.push(out[i]);
        continue;
      }
      result.push(out[i]);
    }
    if (!inserted) {
      // 兜底（理论上不会发生）：退回到"整份文本末尾 END:VCALENDAR 之前"插入
      const tail0: string = result.join(crlf);
      const idxVc: number = tail0.lastIndexOf('END:VCALENDAR');
      if (idxVc > 0) {
        const head: string = tail0.substring(0, idxVc);
        const tail: string = tail0.substring(idxVc);
        const merged: string = head + extra.join(crlf) + crlf + tail;
        return merged.endsWith(crlf) ? merged : merged + crlf;
      }
      for (const ex of extra) {
        result.push(ex);
      }
    }

    const text2: string = result.join(crlf);
    return text2.endsWith(crlf) ? text2 : text2 + crlf;
  }

  /**
   * 在**服务器原文**上改写 VTODO 的内容字段，返回新的整份 ICS。
   *
   * 只改三项，其余（PRIORITY / CATEGORIES / X-* / STATUS / COMPLETED …）原样保留：
   *   - SUMMARY     标题
   *   - DESCRIPTION 备注
   *   - DUE         截止时间（dueMs<=0 → 删除该行）
   *
   * 与 rewriteTodoCompletion 相同的两遍处理：
   *   ① 先定位含目标 uid 的 VTODO 块（RFC 5545 不规定字段顺序，不能边扫边改）
   *   ② 再在块内替换/删除目标字段，缺失的在 END:VTODO 前补齐
   */
  static rewriteTodoFields(ics: string, uid: string, title: string,
    desc: string, dueMs: number): string {
    const crlf: string = '\r\n';
    const unfolded: string = ics.replace(/\r?\n[ \t]/g, '');
    const lines: string[] = unfolded.split(/\r?\n/).map((s: string): string => s.replace(/\r$/, ''));
    const upperOf = (s: string): string => s.toUpperCase();

    // ---- 第 1 遍：定位目标 VTODO 块 ----
    let targetBegin: number = -1;
    let targetEnd: number = -1;
    let curBegin: number = -1;
    let curHasUid: boolean = false;
    for (let i = 0; i < lines.length; i++) {
      const u: string = upperOf(lines[i]);
      if (u.startsWith('BEGIN:VTODO')) {
        curBegin = i;
        curHasUid = false;
        continue;
      }
      if (u.startsWith('UID:') && curBegin >= 0) {
        if (lines[i].substring(4).trim() === uid) {
          curHasUid = true;
        }
        continue;
      }
      if (u.startsWith('END:VTODO')) {
        if (curBegin >= 0 && curHasUid && targetBegin < 0) {
          targetBegin = curBegin;
          targetEnd = i;
        }
        curBegin = -1;
        curHasUid = false;
      }
    }
    if (targetBegin < 0) {
      return ics; // 找不到目标，原样返回
    }

    // ---- 第 2 遍：块内改写 ----
    const out: string[] = [];
    let sawSummary: boolean = false;
    let sawDesc: boolean = false;
    let sawDue: boolean = false;
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i];
      const u: string = upperOf(line);
      const inTarget: boolean = i > targetBegin && i < targetEnd;
      if (!inTarget) {
        out.push(line);
        continue;
      }
      if (u.startsWith('SUMMARY')) {
        sawSummary = true;
        if (title !== '') {
          out.push('SUMMARY:' + IcsUtil.escape(title));
        }
        continue;
      }
      if (u.startsWith('DESCRIPTION')) {
        sawDesc = true;
        if (desc !== '') {
          out.push('DESCRIPTION:' + IcsUtil.escape(desc));
        }
        continue;
      }
      if (u.startsWith('DUE')) {
        sawDue = true;
        if (dueMs > 0) {
          out.push('DUE:' + IcsUtil.fmtIcsTime(dueMs, false));
        }
        continue;
      }
      out.push(line);
    }

    // 缺失字段补齐
    const extra: string[] = [];
    if (!sawSummary && title !== '') {
      extra.push('SUMMARY:' + IcsUtil.escape(title));
    }
    if (!sawDesc && desc !== '') {
      extra.push('DESCRIPTION:' + IcsUtil.escape(desc));
    }
    if (!sawDue && dueMs > 0) {
      extra.push('DUE:' + IcsUtil.fmtIcsTime(dueMs, false));
    }
    if (extra.length === 0) {
      const plain: string = out.join(crlf);
      return plain.endsWith(crlf) ? plain : plain + crlf;
    }

    // 按**结构**定位插入点（不能按行号：上面可能删掉了 DUE 行，行号已不对齐）
    const result: string[] = [];
    let vtodoIdx: number = -1;
    let targetOrdinal: number = -1;
    // 重新数出目标的块序号
    {
      let n: number = -1;
      let inBlk: boolean = false;
      let has: boolean = false;
      for (let i = 0; i < out.length; i++) {
        const u: string = upperOf(out[i]);
        if (u.startsWith('BEGIN:VTODO')) {
          n++;
          inBlk = true;
          has = false;
          continue;
        }
        if (u.startsWith('UID:') && inBlk && out[i].substring(4).trim() === uid) {
          has = true;
          continue;
        }
        if (u.startsWith('END:VTODO') && inBlk) {
          if (has && targetOrdinal < 0) {
            targetOrdinal = n;
          }
          inBlk = false;
        }
      }
    }
    let inserted: boolean = false;
    for (let i = 0; i < out.length; i++) {
      const u: string = upperOf(out[i]);
      if (u.startsWith('BEGIN:VTODO')) {
        vtodoIdx++;
        result.push(out[i]);
        continue;
      }
      if (u.startsWith('END:VTODO')) {
        if (!inserted && vtodoIdx === targetOrdinal) {
          for (const ex of extra) {
            result.push(ex);
          }
          inserted = true;
        }
        // ⚠️ 不要重置 vtodoIdx：它是全局块序号，重置会让下一块从 0 重新数，
        //    多 VTODO 文件里永远匹配不到 targetOrdinal（静默失败）。
        result.push(out[i]);
        continue;
      }
      result.push(out[i]);
    }
    if (!inserted) {
      const tail0: string = result.join(crlf);
      const idxVc: number = tail0.lastIndexOf('END:VCALENDAR');
      if (idxVc > 0) {
        const merged: string = tail0.substring(0, idxVc) + extra.join(crlf) + crlf
          + tail0.substring(idxVc);
        return merged.endsWith(crlf) ? merged : merged + crlf;
      }
      for (const ex of extra) {
        result.push(ex);
      }
    }
    const text2: string = result.join(crlf);
    return text2.endsWith(crlf) ? text2 : text2 + crlf;
  }

  /**
   * 按 FREQ 把时间往后推一个周期（用于"完成一个循环任务 → 生成下一次"）。
   *
   * ⚠️ 月份/年份推进要处理"月末溢出"：
   *    1 月 31 日 + 1 个月 在 JS 里会得到 3 月 3 日（2 月没有 31 日）。
   *    RFC 5545 规定这类"不存在的日期"应当**跳过**而非顺延，
   *    但对家务类待办来说"顺延到 3 号"比"跳过整个月"更符合直觉，
   *    这里采用**钳制到当月最后一天**（1/31 → 2/28），并注释说明取舍。
   *
   * @param freq  DAILY / WEEKLY / MONTHLY / YEARLY
   * @param fromMs 基准时间
   * @returns 下一周期的时间（同一天内时分秒保持不变）
   */
  /** 从 RRULE 原文取出 FREQ 值（DAILY / WEEKLY / MONTHLY / YEARLY）；取不到返回 DAILY */
  static freqOfRrule(rrule: string): string {
    const parts: string[] = rrule.split(';');
    for (const part of parts) {
      const idx: number = part.indexOf('=');
      if (idx <= 0) {
        continue;
      }
      const key: string = part.substring(0, idx).trim().toUpperCase();
      if (key === 'FREQ') {
        return part.substring(idx + 1).trim().toUpperCase();
      }
    }
    return 'DAILY';
  }

  static incForFreq(freq: string, fromMs: number): number {
    const d: Date = new Date(fromMs);
    const f: string = freq.toUpperCase();
    if (f === 'DAILY') {
      return fromMs + 86400000;
    }
    if (f === 'WEEKLY') {
      return fromMs + 7 * 86400000;
    }
    if (f === 'MONTHLY') {
      const y: number = d.getFullYear();
      const m: number = d.getMonth() + 1;
      const day: number = d.getDate();
      const lastDayOfNext: number = new Date(y, m + 1, 0).getDate();
      return new Date(y, m, Math.min(day, lastDayOfNext),
        d.getHours(), d.getMinutes(), d.getSeconds()).getTime();
    }
    if (f === 'YEARLY') {
      const y: number = d.getFullYear() + 1;
      const m: number = d.getMonth();
      const day: number = d.getDate();
      // 2/29 → 次年 2/28（闰年才有 29）
      const lastDay: number = new Date(y, m + 1, 0).getDate();
      return new Date(y, m, Math.min(day, lastDay),
        d.getHours(), d.getMinutes(), d.getSeconds()).getTime();
    }
    return fromMs + 86400000;
  }

  /**
   * 在**服务器原文**上写入循环规则（RRULE + DTSTART + DUE）。
   *
   * 只在这三处动，其余字段（SUMMARY/DESCRIPTION/PRIORITY/X-* …）原样保留。
   *
   * @param rrule   规则原文，如 `FREQ=WEEKLY`；空串 = 取消循环（删除 RRULE/DTSTART，保留 DUE）
   * @param dtstart 重复基准（毫秒）；<=0 时用 dueMs 兜底
   * @param dueMs   本轮的截止时间（毫秒）；<=0 表示无截止
   */
  static rewriteTodoRecurrence(ics: string, uid: string, rrule: string,
    dtstart: number, dueMs: number): string {
    const crlf: string = '\r\n';
    const unfolded: string = ics.replace(/\r?\n[ \t]/g, '');
    const lines: string[] = unfolded.split(/\r?\n/).map((s: string): string => s.replace(/\r$/, ''));
    const upperOf = (s: string): string => s.toUpperCase();
    const hasRule: boolean = rrule.trim() !== '';

    // ---- 第 1 遍：定位目标 VTODO 块（RFC 5545 不规定字段顺序，必须两遍）----
    let targetBegin: number = -1;
    let targetEnd: number = -1;
    let curBegin: number = -1;
    let curHasUid: boolean = false;
    for (let i = 0; i < lines.length; i++) {
      const u: string = upperOf(lines[i]);
      if (u.startsWith('BEGIN:VTODO')) {
        curBegin = i;
        curHasUid = false;
        continue;
      }
      if (u.startsWith('UID:') && curBegin >= 0) {
        if (lines[i].substring(4).trim() === uid) {
          curHasUid = true;
        }
        continue;
      }
      if (u.startsWith('END:VTODO')) {
        if (curBegin >= 0 && curHasUid && targetBegin < 0) {
          targetBegin = curBegin;
          targetEnd = i;
        }
        curBegin = -1;
        curHasUid = false;
      }
    }
    if (targetBegin < 0) {
      return ics;
    }

    // ---- 第 2 遍：块内替换/删除 RRULE、DTSTART、DUE ----
    const out: string[] = [];
    let sawRule: boolean = false;
    let sawStart: boolean = false;
    let sawDue: boolean = false;
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i];
      const u: string = upperOf(line);
      const inTarget: boolean = i > targetBegin && i < targetEnd;
      if (!inTarget) {
        out.push(line);
        continue;
      }
      if (u.startsWith('RRULE')) {
        sawRule = true;
        if (hasRule) {
          out.push('RRULE:' + rrule.trim());
        }
        continue; // 取消循环时整行丢掉
      }
      if (u.startsWith('DTSTART')) {
        sawStart = true;
        if (hasRule && dtstart > 0) {
          out.push('DTSTART:' + IcsUtil.fmtIcsTime(dtstart, false));
        }
        continue;
      }
      if (u.startsWith('DUE')) {
        sawDue = true;
        if (dueMs > 0) {
          out.push('DUE:' + IcsUtil.fmtIcsTime(dueMs, false));
        }
        continue;
      }
      out.push(line);
    }

    // 缺字段补齐
    const extra: string[] = [];
    if (hasRule) {
      if (!sawRule) {
        extra.push('RRULE:' + rrule.trim());
      }
      if (!sawStart && dtstart > 0) {
        extra.push('DTSTART:' + IcsUtil.fmtIcsTime(dtstart, false));
      }
      if (!sawDue && dueMs > 0) {
        extra.push('DUE:' + IcsUtil.fmtIcsTime(dueMs, false));
      }
    }
    if (extra.length === 0) {
      const plain: string = out.join(crlf);
      return plain.endsWith(crlf) ? plain : plain + crlf;
    }

    // 按**结构**定位插入点（改动会删行，行号已不对齐）
    let targetOrdinal: number = -1;
    {
      let n: number = -1;
      let inBlk: boolean = false;
      let has: boolean = false;
      for (let i = 0; i < out.length; i++) {
        const u: string = upperOf(out[i]);
        if (u.startsWith('BEGIN:VTODO')) {
          n++;
          inBlk = true;
          has = false;
          continue;
        }
        if (u.startsWith('UID:') && inBlk && out[i].substring(4).trim() === uid) {
          has = true;
          continue;
        }
        if (u.startsWith('END:VTODO') && inBlk) {
          if (has && targetOrdinal < 0) {
            targetOrdinal = n;
          }
          inBlk = false;
        }
      }
    }
    // ⭐ RRULE_IDX_FIX vtodoIdx 是**全局块序号**，只在 BEGIN:VTODO 自增。
    //    之前在这里的 END:VTODO 分支把它重置成 -1，导致每块都从 0 重新数，
    //    多 VTODO 文件里永远匹配不到 targetOrdinal（第 2 块应为 1）⇒ RRULE 加不上。
    const result: string[] = [];
    let vtodoIdx: number = -1;
    let inserted: boolean = false;
    for (let i = 0; i < out.length; i++) {
      const u: string = upperOf(out[i]);
      if (u.startsWith('BEGIN:VTODO')) {
        vtodoIdx++;
        result.push(out[i]);
        continue;
      }
      if (u.startsWith('END:VTODO')) {
        if (!inserted && vtodoIdx === targetOrdinal) {
          for (const ex of extra) {
            result.push(ex);
          }
          inserted = true;
        }
        result.push(out[i]);
        continue;
      }
      result.push(out[i]);
    }
    if (!inserted) {
      const tail0: string = result.join(crlf);
      const idxVc: number = tail0.lastIndexOf('END:VCALENDAR');
      if (idxVc > 0) {
        const merged: string = tail0.substring(0, idxVc) + extra.join(crlf) + crlf
          + tail0.substring(idxVc);
        return merged.endsWith(crlf) ? merged : merged + crlf;
      }
      for (const ex of extra) {
        result.push(ex);
      }
    }
    const text2: string = result.join(crlf);
    return text2.endsWith(crlf) ? text2 : text2 + crlf;
  }

  /** 解析 VCALENDAR 中的 VTODO 待办列表（待办为只读展示，不参与推送） */
  static parseTodos(ics: string): RemoteEvent[] {
    const unfolded: string = ics.replace(/\r?\n[ \t]/g, '');
    const lines: string[] = unfolded.split(/\r?\n/);
    const parsed: RemoteEvent[] = [];
    let current: RemoteEvent | null = null;
    for (const line of lines) {
      const upper: string = line.toUpperCase();
      if (upper.startsWith('BEGIN:VTODO')) {
        current = new RemoteEvent();
        current.isTodo = true;
        continue;
      }
      if (upper.startsWith('END:VTODO')) {
        if (current !== null && current.uid !== '') {
          parsed.push(current);
        }
        current = null;
        continue;
      }
      if (current === null) {
        continue;
      }
      const colon: number = line.indexOf(':');
      if (colon <= 0) {
        continue;
      }
      const propPart: string = line.substring(0, colon);
      const value: string = line.substring(colon + 1).trim();
      const propName: string = propPart.split(';')[0].toUpperCase();
      if (propName === 'UID') {
        current.uid = value;
      } else if (propName === 'SUMMARY') {
        current.title = IcsUtil.unescape(value);
      } else if (propName === 'DESCRIPTION') {
        current.description = IcsUtil.unescape(value);
      } else if (propName === 'LOCATION') {
        current.location = IcsUtil.unescape(value);
      } else if (propName === 'RRULE') {
        current.recurring = true;
        // ⭐ 保存规则原文：原来只置了 recurring 标志，规则本身被丢掉，
        //    导致「知道它重复，但不知道多久重复一次」。
        current.rrule = value.trim();
      } else if (propName === 'DTSTART') {
        // ⭐ DTSTART 单独存：它是 RRULE 的重复基准，**不是**截止时间。
        //    原来与 DUE 共用 startTime，谁后出现谁覆盖 ⇒ 循环任务基准错乱。
        const isDateOnly: boolean = propPart.toUpperCase().includes('VALUE=DATE');
        const t = IcsUtil.parseTime(value, isDateOnly);
        if (t !== null) {
          current.dtstart = t.time;
        }
      } else if (propName === 'DUE') {
        const isDateOnly: boolean = propPart.toUpperCase().includes('VALUE=DATE');
        const t = IcsUtil.parseTime(value, isDateOnly);
        if (t !== null) {
          current.startTime = t.time;
          // 全天待办截止日按当天结束存储；普通待办开始=截止
          current.endTime = t.allDay ? t.time + 86399000 : t.time;
          current.isAllDay = t.allDay;
        }
      } else if (propName === 'STATUS') {
        if (value.toUpperCase() === 'COMPLETED') {
          current.completed = true;
        }
      }
    }
    return parsed;
  }

  /**
   * 由本地事件构建 VCALENDAR 文本。
   *
   * ⚠️ 事件时间写的是**浮动本地时间**（不是 UTC），原因见 `vevent()` 里的详细说明
   *    （服务器会删掉 `Z`/`TZID` 且不做时移）。`DTSTAMP` 仍按 RFC 规定写 UTC+`Z`。
   *
   * 已知取舍：摘要 / 地点 / 备注等文本字段**未做 ICS 转义**（`,` `;` `\` 与换行）。
   * 含这些字符的标题在服务器端可能被截断或串行；
   * 若线上出现"标题被截断"反馈，需在此补 escapeIcsText()。
   */
  static build(e: LocalEvent): string {
    const now: string = IcsUtil.fmtUtcNow();
    return 'BEGIN:VCALENDAR\r\n' +
      'VERSION:2.0\r\n' +
      'PRODID:-//SyncCalendar//Calendar//CN\r\n' +
      'CALSCALE:GREGORIAN\r\n' +
      IcsUtil.vevent(e, now) +
      'END:VCALENDAR\r\n';
  }

  /**
   * 从零构造一份 VTODO 资源（新建待办用）。
   *
   * @param uid   待办全局唯一标识
   * @param title 标题
   * @param desc  备注（可为空，空则不写 DESCRIPTION）
   * @param dueMs 截止时间毫秒（0 = 无截止时间，不写 DUE）
   * @param dueIsDateOnly 截止时间是否"只有日期无时刻"（true 写 `DUE;VALUE=DATE`）
   */
  static buildTodo(uid: string, title: string, desc: string, dueMs: number,
    dueIsDateOnly: boolean): string {
    const now: string = IcsUtil.fmtUtcNow();
    let out: string = 'BEGIN:VCALENDAR\r\n' +
      'VERSION:2.0\r\n' +
      'PRODID:-//SyncCalendar//Calendar//CN\r\n' +
      'CALSCALE:GREGORIAN\r\n' +
      'BEGIN:VTODO\r\n' +
      `UID:${uid}\r\n` +
      `DTSTAMP:${now}\r\n` +
      `SUMMARY:${IcsUtil.escape(title)}\r\n`;
    if (desc !== '') {
      out += `DESCRIPTION:${IcsUtil.escape(desc)}\r\n`;
    }
    if (dueMs > 0) {
      if (dueIsDateOnly) {
        out += `DUE;VALUE=DATE:${IcsUtil.fmtIcsTime(dueMs, true)}\r\n`;
      } else {
        out += `DUE:${IcsUtil.fmtIcsTime(dueMs, false)}\r\n`;
      }
    }
    // 新建待办一律"未开始"，完成态由 setCompleted 切换到 COMPLETED
    out += 'STATUS:NEEDS-ACTION\r\n';
    out += 'END:VTODO\r\n';
    out += 'END:VCALENDAR\r\n';
    return out;
  }

  /**
   * ⭐ 构建"一个重复系列"的完整资源：**主事件 + 全部覆盖实例**放在同一个 VCALENDAR 里。
   *
   * 为什么必须合在一起：CalDAV 里"重复日程的某一次发生被单独修改"的标准表示法是
   * 在**同一个 .ics 资源**里放第二个 VEVENT，带 `RECURRENCE-ID` 指向被覆盖的那一次。
   * 早先 App 直接把每个实例当独立资源 PUT，会破坏服务器上的整个系列，所以那时干脆
   * 禁止了单次修改（见旧版"重复日程的单次修改暂不支持"）。现在改为重建整份系列后推送。
   *
   * @param master 主事件行（含 RRULE / EXDATE）
   * @param overrides 覆盖实例行（rrule 为空、recurrenceId > 0），已排除 deleted
   */
  static buildSeries(master: LocalEvent, overrides: LocalEvent[]): string {
    const now: string = IcsUtil.fmtUtcNow();
    let out: string = 'BEGIN:VCALENDAR\r\n' +
      'VERSION:2.0\r\n' +
      'PRODID:-//SyncCalendar//Calendar//CN\r\n' +
      'CALSCALE:GREGORIAN\r\n' +
      IcsUtil.vevent(master, now);
    for (const ov of overrides) {
      out += IcsUtil.vevent(ov, now);
    }
    out += 'END:VCALENDAR\r\n';
    return out;
  }

  /** 单个 VEVENT 块（主事件带 RRULE/EXDATE，覆盖行带 RECURRENCE-ID） */
  private static vevent(e: LocalEvent, now: string): string {
    const pad = (n: number): string => n < 10 ? '0' + n : String(n);
    /**
     * ⭐⭐ 事件时间一律写**浮动本地时间**（`YYYYMMDDTHHMMSS`，**不带 `Z`、不带 `TZID`**）。
     *
     * 为什么不写 RFC 最正统的 UTC+`Z` —— 因为服务器会把它弄坏：
     *   本项目的服务器（家书日历 / family.yangyq.net）会**直接删掉** `DTSTART`/`DTEND`
     *   上的 `Z` 与 `TZID` 参数，**且不对数值做任何时移**
     *   （2026-10-15 实测：PUT `DTSTART:20261020T060000Z` → 存回 `DTSTART:20261020T060000`；
     *     PUT `DTSTART;TZID=Asia/Shanghai:20261020T140000` → 存回 `20261020T140000`）。
     *   于是"UTC 00:00"被当成"**本地** 00:00"。而本地 08:00 的正确 UTC 恰好就是 00:00，
     *   所以症状正好是**阅读端少了 8 小时**（用户实测："8:00 的日程同步后变成 0:00"）。
     *
     * 该服务器上全部计时事件（1163 条）的 `DTSTART` **无一例外都是浮动本地时间**
     * （带 `Z` 的数量为 **0**、带 `TZID` 为 **0**）→ 这就是它的事实约定，我们随它。
     * 浮动时间在任何阅读端都按"当地墙钟"解析，本机 CST 往返完全一致。
     */
    const fmtLocal = (ms: number): string => {
      const d = new Date(ms);
      return `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}` +
        `T${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`;
    };
    const fmtDate = (ms: number): string => {
      const d = new Date(ms);
      return `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}`;
    };
    let dtstart: string;
    let dtend: string;
    if (e.isAllDay) {
      dtstart = 'DTSTART;VALUE=DATE:' + fmtDate(e.startTime);
      // 存储的 endTime 为排他日前一毫秒，+1s 得到排他日期
      dtend = 'DTEND;VALUE=DATE:' + fmtDate(e.endTime + 1000);
    } else {
      dtstart = 'DTSTART:' + fmtLocal(e.startTime);
      dtend = 'DTEND:' + fmtLocal(e.endTime);
    }
    // ⭐ 覆盖实例（RECURRENCE-ID 行）：必须写出 RECURRENCE-ID，否则服务器无法把它
    //    关联到主事件的哪一次发生 → 要么整系列被破坏，要么原时间残留成"幽灵日程"。
    let recId: string = '';
    if (e.rrule === '' && e.recurrenceId > 0) {
      recId = e.isAllDay
        ? `RECURRENCE-ID;VALUE=DATE:${fmtDate(e.recurrenceId)}\r\n`
        : `RECURRENCE-ID:${fmtLocal(e.recurrenceId)}\r\n`;
    }
    // ⭐ EXDATE：主事件排除掉的若干次发生（"仅删除这一次"就是往这里加）
    let exdate: string = '';
    if (e.exdate !== '') {
      const vals: string[] = [];
      for (const raw of e.exdate.split(';')) {
        const t = IcsUtil.parseTime(raw, !raw.includes('T'));
        if (t !== null) {
          vals.push(t.allDay ? fmtDate(t.time) : fmtLocal(t.time));
        }
      }
      if (vals.length > 0) {
        exdate = e.isAllDay
          ? `EXDATE;VALUE=DATE:${vals.join(',')}\r\n`
          : `EXDATE:${vals.join(',')}\r\n`;
      }
    }
    return 'BEGIN:VEVENT\r\n' +
      `UID:${e.uid}\r\n` +
      `DTSTAMP:${now}\r\n` +
      `${dtstart}\r\n` +
      `${dtend}\r\n` +
      recId +
      (e.rrule !== '' ? `RRULE:${e.rrule}\r\n` : '') +
      exdate +
      `SUMMARY:${IcsUtil.escape(e.title)}\r\n` +
      (e.location !== '' ? `LOCATION:${IcsUtil.escape(e.location)}\r\n` : '') +
      (e.description !== '' ? `DESCRIPTION:${IcsUtil.escape(e.description)}\r\n` : '') +
      IcsUtil.valarms(e.reminders.length > 0 ? e.reminders
        : (e.reminder > 0 ? [e.reminder] : [])) +
      'END:VEVENT\r\n';
  }

  /** 当前时刻的 UTC 形式（DTSTAMP） */
  private static fmtUtcNow(): string {
    const pad = (n: number): string => n < 10 ? '0' + n : String(n);
    const d = new Date();
    return `${d.getUTCFullYear()}${pad(d.getUTCMonth() + 1)}${pad(d.getUTCDate())}` +
      `T${pad(d.getUTCHours())}${pad(d.getUTCMinutes())}${pad(d.getUTCSeconds())}Z`;
  }

  /**
   * 毫秒时间戳 → 用于 EXDATE / RECURRENCE-ID / UNTIL 的 ICS 时间串。
   * @param dateOnly 全天日程用 `YYYYMMDD`，否则用**浮动本地时间** `YYYYMMDDTHHMMSS`
   *                 （不带 `Z`：必须与 `DTSTART` 的形态一致，见 `vevent()` 里的说明）
   */
  static fmtIcsTime(ms: number, dateOnly: boolean): string {
    const pad = (n: number): string => n < 10 ? '0' + n : String(n);
    const d = new Date(ms);
    if (dateOnly) {
      return `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}`;
    }
    return `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}` +
      `T${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`;
  }

  /**
   * ⭐ 给 RRULE 加上/替换 UNTIL（"此次及以后"改期/删除时，把原系列截断到指定时刻之前）。
   * - 会**移除 COUNT**（RFC 5545：UNTIL 与 COUNT 不可同时出现）
   * - UNTIL 用**浮动本地时间**（RFC 5545：`DTSTART` 是本地时间时，`UNTIL` **必须**也是本地时间；
   *   而我们把所有事件时间都写成浮动本地 —— 二者必须一致，否则不同阅读端的展开会错位）
   * - `untilMs` 一般是"该次发生的开始时刻 − 1 秒"
   */
  static rruleWithUntil(rrule: string, untilMs: number): string {
    const until: string = IcsUtil.fmtIcsTime(untilMs, false);
    const kept: string[] = [];
    for (const part of rrule.split(';')) {
      const k: string = part.split('=')[0].trim().toUpperCase();
      if (k === 'UNTIL' || k === 'COUNT' || k === '') {
        continue;
      }
      kept.push(part);
    }
    kept.push(`UNTIL=${until}`);
    return kept.join(';');
  }

  /** 由提醒分钟数组生成多个 VALARM（已规范化去重） */
  private static valarms(minutes: number[]): string {
    let out: string = '';
    for (const m of minutes) {
      if (m > 0) {
        out += IcsUtil.valarm(m);
      }
    }
    return out;
  }

  /** 由提前分钟数生成 VALARM（TRIGGER 负时长 = 提前触发） */
  private static valarm(minutes: number): string {
    let trigger: string;
    if (minutes >= 1440 && minutes % 1440 === 0) {
      trigger = `-P${minutes / 1440}D`;
    } else if (minutes >= 60 && minutes % 60 === 0) {
      trigger = `-PT${minutes / 60}H`;
    } else {
      trigger = `-PT${minutes}M`;
    }
    return 'BEGIN:VALARM\r\n' +
      `TRIGGER:${trigger}\r\n` +
      'ACTION:DISPLAY\r\n' +
      'DESCRIPTION:提醒\r\n' +
      'END:VALARM\r\n';
  }

  static escape(s: string): string {
    return s.replace(/\\/g, '\\\\').replace(/;/g, '\\;').replace(/,/g, '\\,').replace(/\n/g, '\\n');
  }

  private static unescape(s: string): string {
    return s.replace(/\\n/gi, '\n').replace(/\\,/g, ',').replace(/\\;/g, ';').replace(/\\\\/g, '\\');
  }

  /** 解析 iCal DURATION（ISO 8601 时长，如 PT1H30M / P2D / P1W），返回毫秒 */
  private static parseDurationMs(value: string): number {
    const m = /^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/
      .exec(value.trim().toUpperCase());
    if (m === null) {
      return 0;
    }
    const sign: number = m[1] === '-' ? -1 : 1;
    const w: number = Number(m[2] ?? '0');
    const d: number = Number(m[3] ?? '0');
    const h: number = Number(m[4] ?? '0');
    const mi: number = Number(m[5] ?? '0');
    const s: number = Number(m[6] ?? '0');
    const total: number = (((w * 7 + d) * 24 + h) * 60 + mi) * 60 + s;
    return sign * total * 1000;
  }

  /** 解析 iCal 时间值，返回 13 位毫秒时间戳（供 EXDATE 解析等复用） */
  static parseTime(value: string, dateOnly: boolean): IcsTime | null {
    const v: string = value.trim();
    if (/^\d{8}$/.test(v) || dateOnly) {
      const m = /^(\d{4})(\d{2})(\d{2})/.exec(v);
      if (m === null) {
        return null;
      }
      const t = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3])).getTime();
      const result = new IcsTime();
      result.time = t;
      result.allDay = true;
      return result;
    }
    const m2 = /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(Z?)$/.exec(v);
    if (m2 === null) {
      return null;
    }
    const isUtc: boolean = m2[7] === 'Z';
    let t2: number;
    if (isUtc) {
      t2 = Date.UTC(Number(m2[1]), Number(m2[2]) - 1, Number(m2[3]),
        Number(m2[4]), Number(m2[5]), Number(m2[6]));
    } else {
      // TZID 时区未做完整换算，按设备本地时区近似
      t2 = new Date(Number(m2[1]), Number(m2[2]) - 1, Number(m2[3]),
        Number(m2[4]), Number(m2[5]), Number(m2[6])).getTime();
    }
    const result2 = new IcsTime();
    result2.time = t2;
    result2.allDay = false;
    return result2;
  }
}