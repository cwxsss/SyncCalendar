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
  reminder: number = 0;     // 提醒提前分钟数（来自 VALARM TRIGGER，0 = 不提醒）
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
            current.reminder = IcsUtil.triggerMinutes(av, ap);
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
      } else if (propName === 'RRULE' || propName === 'RECURREIENCE-ID') {
        current.recurring = true;
        if (propName === 'RRULE') {
          current.rrule = value;
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
      r.reminder = p.reminder;
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

  /** 由本地事件构建 VCALENDAR 文本（时间统一转 UTC，保证服务器端时区正确） */
  static build(e: LocalEvent): string {
    const pad = (n: number): string => n < 10 ? '0' + n : String(n);
    const fmtUtc = (ms: number): string => {
      const d = new Date(ms);
      return `${d.getUTCFullYear()}${pad(d.getUTCMonth() + 1)}${pad(d.getUTCDate())}` +
        `T${pad(d.getUTCHours())}${pad(d.getUTCMinutes())}${pad(d.getUTCSeconds())}Z`;
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
      dtstart = 'DTSTART:' + fmtUtc(e.startTime);
      dtend = 'DTEND:' + fmtUtc(e.endTime);
    }
    const now: string = fmtUtc(Date.now());
    return 'BEGIN:VCALENDAR\r\n' +
      'VERSION:2.0\r\n' +
      'PRODID:-//SyncCalendar//Calendar//CN\r\n' +
      'CALSCALE:GREGORIAN\r\n' +
      'BEGIN:VEVENT\r\n' +
      `UID:${e.uid}\r\n` +
      `DTSTAMP:${now}\r\n` +
      `${dtstart}\r\n` +
      `${dtend}\r\n` +
      `SUMMARY:${IcsUtil.escape(e.title)}\r\n` +
      (e.location !== '' ? `LOCATION:${IcsUtil.escape(e.location)}\r\n` : '') +
      (e.description !== '' ? `DESCRIPTION:${IcsUtil.escape(e.description)}\r\n` : '') +
      'END:VEVENT\r\n' +
      'END:VCALENDAR\r\n';
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