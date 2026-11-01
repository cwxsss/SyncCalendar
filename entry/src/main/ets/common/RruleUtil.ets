// entry/src/main/ets/common/RruleUtil.ets
// RRULE 展开：支持 DAILY / WEEKLY / MONTHLY / YEARLY
// 支持 INTERVAL、COUNT、UNTIL、BYDAY(周重复，如 MO,WE,FR)、BYMONTHDAY(月重复)
export const DAY_MS: number = 86400000;

export class RruleUtil {
  /**
   * 展开重复规则，返回窗口内的发生时刻（毫秒时间戳）。
   * @param rrule      原始 RRULE 值（如 FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH）
   * @param dtstart    首次发生时间（毫秒）
   * @param windowStart 窗口起点（毫秒）
   * @param windowEnd   窗口终点（毫秒）
   * @param exdates    EXDATE 排除时刻列表（毫秒），按整天或精确值匹配
   * @param maxCount   结果数量上限（防止超大结果）
   */
  static expand(rrule: string, dtstart: number, windowStart: number, windowEnd: number,
    exdates: number[], maxCount: number): number[] {
    const result: number[] = [];
    if (rrule.trim() === '') {
      return result;
    }
    let freq: string = '';
    let interval: number = 1;
    let count: number = -1;
    let until: number = 0;
    let byday: string[] = [];
    let bymonthday: number[] = [];
    const parts: string[] = rrule.split(';');
    for (const part of parts) {
      const idx: number = part.indexOf('=');
      if (idx <= 0) {
        continue;
      }
      const key: string = part.substring(0, idx).trim().toUpperCase();
      const value: string = part.substring(idx + 1).trim();
      if (key === 'FREQ') {
        freq = value.toUpperCase();
      } else if (key === 'INTERVAL') {
        interval = Math.max(1, Number(value));
      } else if (key === 'COUNT') {
        count = Number(value);
      } else if (key === 'UNTIL') {
        until = RruleUtil.parseUntil(value);
      } else if (key === 'BYDAY') {
        byday = value.split(',').map((s: string): string => s.trim().toUpperCase());
      } else if (key === 'BYMONTHDAY') {
        bymonthday = value.split(',').map((s: string): number => Number(s.trim()));
      }
    }
    if (freq === '' || Number.isNaN(interval) || interval < 1) {
      return result;
    }

    const base = new Date(dtstart);
    const baseZero = new Date(dtstart);
    baseZero.setHours(0, 0, 0, 0);
    const baseZeroMs: number = baseZero.getTime();
    const timeOfDay: number = dtstart - baseZeroMs;
    let generated: number = 0;

    // 接受一个发生：处理 COUNT/UNTIL/EXDATE/窗口过滤
    const accept = (occ: number): boolean => {
      if (count > 0 && generated >= count) {
        return false;
      }
      if (until > 0 && occ > until) {
        return false;
      }
      generated++;
      if (occ >= dtstart && occ <= windowEnd + DAY_MS - 1000 && occ >= windowStart - 40 * DAY_MS) {
        const occDay: number = RruleUtil.dayFloor(occ);
        let excluded: boolean = false;
        for (const ex of exdates) {
          if (ex === occ || RruleUtil.dayFloor(ex) === occDay) {
            excluded = true;
            break;
          }
        }
        if (!excluded && result.length < maxCount) {
          result.push(occ);
        }
      }
      return true;
    };

    if (freq === 'DAILY') {
      let occ: number = dtstart;
      let guard: number = 0;
      while (occ <= windowEnd + DAY_MS && guard < 5000) {
        guard++;
        if (!accept(occ)) {
          break;
        }
        const d = new Date(occ);
        d.setDate(d.getDate() + interval);
        occ = d.getTime();
      }
    } else if (freq === 'WEEKLY') {
      const targets: number[] = [];
      if (byday.length > 0) {
        for (const code of byday) {
          const wd: number = RruleUtil.weekdayFromCode(code);
          if (wd >= 0) {
            targets.push(wd);
          }
        }
      }
      if (targets.length === 0) {
        targets.push(base.getDay());
      }
      // RFC 5545：DTSTART 始终是第一次发生——即使它的星期不在 BYDAY 中
      // （例如周二创建的"每周一重复"日程，第一次是周二那次，必须显示）
      if (byday.length > 0 && !targets.includes(base.getDay())) {
        if (!accept(dtstart)) {
          return result;
        }
      }
      const anchorWeek: number = RruleUtil.weekStartMs(dtstart);
      let dayMs: number = baseZeroMs;
      let guard: number = 0;
      while (dayMs <= windowEnd + DAY_MS && guard < 5000) {
        guard++;
        const wd: number = new Date(dayMs).getDay();
        if (targets.includes(wd)) {
          const weekIndex: number =
            Math.round((RruleUtil.weekStartMs(dayMs) - anchorWeek) / (7 * DAY_MS));
          if (weekIndex % interval === 0) {
            if (!accept(dayMs + timeOfDay)) {
              break;
            }
          }
        }
        dayMs += DAY_MS;
      }
    } else if (freq === 'MONTHLY') {
      let y: number = base.getFullYear();
      let m: number = base.getMonth();
      let guard: number = 0;
      // RFC 5545：DTSTART 始终是第一次发生——即使它的日期不在 BYMONTHDAY 中
      if (bymonthday.length > 0 &&
        !bymonthday.some((v: number): boolean => v === base.getDate())) {
        if (!accept(dtstart)) {
          return result;
        }
      }
      while (guard < 1500) {
        guard++;
        const monthFirst: number = new Date(y, m, 1).getTime();
        if (monthFirst > windowEnd + DAY_MS) {
          break;
        }
        const days: number[] = (bymonthday.length > 0 && !bymonthday.some((v: number): boolean => Number.isNaN(v)))
          ? bymonthday : [base.getDate()];
        let stop: boolean = false;
        for (const md of days) {
          const dim: number = new Date(y, m + 1, 0).getDate();
          if (md >= 1 && md <= dim) {
            const occ: number = new Date(y, m, md,
              base.getHours(), base.getMinutes(), base.getSeconds()).getTime();
            if (!accept(occ)) {
              stop = true;
              break;
            }
          }
        }
        if (stop) {
          break;
        }
        m += interval;
        while (m > 11) {
          m -= 12;
          y++;
        }
      }
    } else if (freq === 'YEARLY') {
      let y: number = base.getFullYear();
      let guard: number = 0;
      while (guard < 300) {
        guard++;
        const occ: number = new Date(y, base.getMonth(), base.getDate(),
          base.getHours(), base.getMinutes(), base.getSeconds()).getTime();
        if (occ > windowEnd + DAY_MS) {
          break;
        }
        if (!accept(occ)) {
          break;
        }
        y += interval;
      }
    }
    return result;
  }

  /** 当天 0 点 */
  static dayFloor(ms: number): number {
    const d = new Date(ms);
    d.setHours(0, 0, 0, 0);
    return d.getTime();
  }

  /** 所在周的周一 0 点 */
  static weekStartMs(ms: number): number {
    const d = new Date(ms);
    d.setHours(0, 0, 0, 0);
    const offset: number = (d.getDay() + 6) % 7;
    return d.getTime() - offset * DAY_MS;
  }

  /** BYDAY 代码 → getDay() 星期值（0=周日）；2TU 等带序号的取后两位 */
  static weekdayFromCode(code: string): number {
    if (code.startsWith('MO')) {
      return 1;
    }
    if (code.startsWith('TU')) {
      return 2;
    }
    if (code.startsWith('WE')) {
      return 3;
    }
    if (code.startsWith('TH')) {
      return 4;
    }
    if (code.startsWith('FR')) {
      return 5;
    }
    if (code.startsWith('SA')) {
      return 6;
    }
    if (code.startsWith('SU')) {
      return 0;
    }
    return -1;
  }

  /** UNTIL 值：20260913T235959Z / 20260913T235959 / 20260913 */
  private static parseUntil(value: string): number {
    const v: string = value.trim().toUpperCase();
    if (/^\d{8}$/.test(v)) {
      return new Date(Number(v.substring(0, 4)), Number(v.substring(4, 6)) - 1,
        Number(v.substring(6, 8)), 23, 59, 59).getTime();
    }
    const m = /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z?$/.exec(v);
    if (m === null) {
      return 0;
    }
    if (v.endsWith('Z')) {
      return Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]),
        Number(m[4]), Number(m[5]), Number(m[6]));
    }
    return new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]),
      Number(m[4]), Number(m[5]), Number(m[6])).getTime();
  }


  /**
   * 计算指定规则在基准时间之后的下一次发生时刻（毫秒）。
   * @param rrule 原始 RRULE 字符串
   * @param currentMs 当前截止时间或发生时间（毫秒）
   * @returns 下一次发生时刻毫秒戳；若重复已终止或规则无效则返回 0
   */
  static nextOccurrence(rrule: string, currentMs: number): number {
    if (rrule.trim() === '' || currentMs <= 0) {
      return 0;
    }
    const winEnd = currentMs + 730 * DAY_MS; // 往后寻找两年区间
    const occs = RruleUtil.expand(rrule, currentMs, currentMs, winEnd, [], 20);
    for (const occ of occs) {
      if (occ > currentMs) {
        return occ;
      }
    }
    return 0;
  }
}
