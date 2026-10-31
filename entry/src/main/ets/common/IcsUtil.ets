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
    const unfolded: string = ics.replace(/\r?\r\n[ \t]/g, '');
    const lines: string[] = unfolded.split(/\r?\r\n/);
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

  /** 解析 VCALENDAR 中的 VTODO 待办列表（待办为只读展示，不参与推送） */
  static parseTodos(ics: string): RemoteEvent[] {
    const unfolded: string = ics.replace(/\r?\r\n[ \t]/g, '');
    const lines: string[] = unfolded.split(/\r?\r\n/);
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
      } else if (propName === 'DUE' || propName === 'DTSTART') {
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
    return s.replace(/\\/g, '\\\\').replace(/;/g, '\\;').replace(/,/g, '\\,').replace(/\r\n/g, '\\r\n');
  }

  private static unescape(s: string): string {
    return s.replace(/\\r\n/gi, '\r\n').replace(/\\,/g, ',').replace(/\\;/g, ';').replace(/\\\\/g, '\\');
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

  /** 标准 VTODO 字符串双向同步到 CalDAV 服务器 */
    /** 标准 VTODO 字符串双向同步到 CalDAV 服务器 */
  static buildTodo(e: LocalEvent): string {
    const pad = (n: number): string => (n < 10 ? '0' : '') + n;
    const fmtLocal = (ms: number): string => {
      const d = new Date(ms);
      return String(d.getFullYear()) + pad(d.getMonth() + 1) + pad(d.getDate()) +
        'T' + pad(d.getHours()) + pad(d.getMinutes()) + pad(d.getSeconds());
    };
    const nowUtc: string = IcsUtil.fmtUtcNow();
    const escapeText = (text: string): string => text
      .replace(/\\/g, '\\\\')
      .replace(/;/g, '\\;')
      .replace(/,/g, '\\,')
      .replace(/\r?\n/g, '\\n');

    let lines: string = 'BEGIN:VCALENDAR\r\n' +
      'VERSION:2.0\r\n' +
      'PRODID:-//XiaoChu//SyncCalendar//CN\r\n' +
      'CALSCALE:GREGORIAN\r\n' +
      'BEGIN:VTODO\r\n' +
      'UID:' + e.uid + '\r\n' +
      'DTSTAMP:' + nowUtc + '\r\n' +
      'SUMMARY:' + escapeText(e.title) + '\r\n';

    if (e.description !== '') {
      lines += 'DESCRIPTION:' + escapeText(e.description) + '\r\n';
    }
    if (e.startTime > 0) {
      lines += 'DUE:' + fmtLocal(e.startTime) + '\r\n';
    }
    if (e.completed) {
      lines += 'STATUS:COMPLETED\r\n' +
        'PERCENT-COMPLETE:100\r\n' +
        'COMPLETED:' + nowUtc + '\r\n';
    } else {
      lines += 'STATUS:NEEDS-ACTION\r\n' +
        'PERCENT-COMPLETE:0\r\n';
    }
    lines += 'END:VTODO\r\nEND:VCALENDAR\r\n';
    return lines;
  }
}
