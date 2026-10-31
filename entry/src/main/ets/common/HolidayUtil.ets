// entry/src/main/ets/common/HolidayUtil.ets
// 中国法定节假日与调休补班数据管理工具（休 / 班 角标及节日名称展示）

export interface HolidayInfo {
  type: 'holiday' | 'workday'; // 'holiday' = 休（放假）, 'workday' = 班（周末调休补班）
  name: string;                // 节日名称，如 "春节"、"国庆节"、"元旦" 等
  badge: string;               // '休' | '班'
}

export class HolidayUtil {
  // 离线节假日与调休数据表（Key 格式：YYYY-MM-DD）
  // 覆盖 2024、2025、2026、2027 年
  private static readonly DATA: Record<string, HolidayInfo> = {
    // ===== 2024 年 =====
    '2024-01-01': { type: 'holiday', name: '元旦', badge: '休' },
    '2024-02-04': { type: 'workday', name: '春节调休', badge: '班' },
    '2024-02-10': { type: 'holiday', name: '春节', badge: '休' },
    '2024-02-11': { type: 'holiday', name: '春节', badge: '休' },
    '2024-02-12': { type: 'holiday', name: '春节', badge: '休' },
    '2024-02-13': { type: 'holiday', name: '春节', badge: '休' },
    '2024-02-14': { type: 'holiday', name: '春节', badge: '休' },
    '2024-02-15': { type: 'holiday', name: '春节', badge: '休' },
    '2024-02-16': { type: 'holiday', name: '春节', badge: '休' },
    '2024-02-17': { type: 'holiday', name: '春节', badge: '休' },
    '2024-02-18': { type: 'workday', name: '春节调休', badge: '班' },
    '2024-04-04': { type: 'holiday', name: '清明节', badge: '休' },
    '2024-04-05': { type: 'holiday', name: '清明节', badge: '休' },
    '2024-04-06': { type: 'holiday', name: '清明节', badge: '休' },
    '2024-04-07': { type: 'workday', name: '清明调休', badge: '班' },
    '2024-04-28': { type: 'workday', name: '劳动节调休', badge: '班' },
    '2024-05-01': { type: 'holiday', name: '劳动节', badge: '休' },
    '2024-05-02': { type: 'holiday', name: '劳动节', badge: '休' },
    '2024-05-03': { type: 'holiday', name: '劳动节', badge: '休' },
    '2024-05-04': { type: 'holiday', name: '劳动节', badge: '休' },
    '2024-05-05': { type: 'holiday', name: '劳动节', badge: '休' },
    '2024-05-11': { type: 'workday', name: '劳动节调休', badge: '班' },
    '2024-06-10': { type: 'holiday', name: '端午节', badge: '休' },
    '2024-09-14': { type: 'workday', name: '中秋节调休', badge: '班' },
    '2024-09-15': { type: 'holiday', name: '中秋节', badge: '休' },
    '2024-09-16': { type: 'holiday', name: '中秋节', badge: '休' },
    '2024-09-17': { type: 'holiday', name: '中秋节', badge: '休' },
    '2024-09-29': { type: 'workday', name: '国庆节调休', badge: '班' },
    '2024-10-01': { type: 'holiday', name: '国庆节', badge: '休' },
    '2024-10-02': { type: 'holiday', name: '国庆节', badge: '休' },
    '2024-10-03': { type: 'holiday', name: '国庆节', badge: '休' },
    '2024-10-04': { type: 'holiday', name: '国庆节', badge: '休' },
    '2024-10-05': { type: 'holiday', name: '国庆节', badge: '休' },
    '2024-10-06': { type: 'holiday', name: '国庆节', badge: '休' },
    '2024-10-07': { type: 'holiday', name: '国庆节', badge: '休' },
    '2024-10-12': { type: 'workday', name: '国庆节调休', badge: '班' },

    // ===== 2025 年 =====
    '2025-01-01': { type: 'holiday', name: '元旦', badge: '休' },
    '2025-01-26': { type: 'workday', name: '春节调休', badge: '班' },
    '2025-01-28': { type: 'holiday', name: '春节', badge: '休' },
    '2025-01-29': { type: 'holiday', name: '春节', badge: '休' },
    '2025-01-30': { type: 'holiday', name: '春节', badge: '休' },
    '2025-01-31': { type: 'holiday', name: '春节', badge: '休' },
    '2025-02-01': { type: 'holiday', name: '春节', badge: '休' },
    '2025-02-02': { type: 'holiday', name: '春节', badge: '休' },
    '2025-02-03': { type: 'holiday', name: '春节', badge: '休' },
    '2025-02-04': { type: 'holiday', name: '春节', badge: '休' },
    '2025-02-08': { type: 'workday', name: '春节调休', badge: '班' },
    '2025-04-04': { type: 'holiday', name: '清明节', badge: '休' },
    '2025-04-05': { type: 'holiday', name: '清明节', badge: '休' },
    '2025-04-06': { type: 'holiday', name: '清明节', badge: '休' },
    '2025-04-27': { type: 'workday', name: '劳动节调休', badge: '班' },
    '2025-05-01': { type: 'holiday', name: '劳动节', badge: '休' },
    '2025-05-02': { type: 'holiday', name: '劳动节', badge: '休' },
    '2025-05-03': { type: 'holiday', name: '劳动节', badge: '休' },
    '2025-05-04': { type: 'holiday', name: '劳动节', badge: '休' },
    '2025-05-05': { type: 'holiday', name: '劳动节', badge: '休' },
    '2025-05-31': { type: 'holiday', name: '端午节', badge: '休' },
    '2025-06-01': { type: 'holiday', name: '端午节', badge: '休' },
    '2025-06-02': { type: 'holiday', name: '端午节', badge: '休' },
    '2025-09-28': { type: 'workday', name: '国庆节调休', badge: '班' },
    '2025-10-01': { type: 'holiday', name: '国庆节', badge: '休' },
    '2025-10-02': { type: 'holiday', name: '国庆节', badge: '休' },
    '2025-10-03': { type: 'holiday', name: '国庆节', badge: '休' },
    '2025-10-04': { type: 'holiday', name: '国庆节', badge: '休' },
    '2025-10-05': { type: 'holiday', name: '国庆节', badge: '休' },
    '2025-10-06': { type: 'holiday', name: '中秋节', badge: '休' },
    '2025-10-07': { type: 'holiday', name: '国庆节', badge: '休' },
    '2025-10-08': { type: 'holiday', name: '国庆节', badge: '休' },
    '2025-10-11': { type: 'workday', name: '国庆节调休', badge: '班' },

    // ===== 2026 年 =====
    '2026-01-01': { type: 'holiday', name: '元旦', badge: '休' },
    '2026-01-02': { type: 'holiday', name: '元旦', badge: '休' },
    '2026-01-03': { type: 'holiday', name: '元旦', badge: '休' },
    '2026-01-04': { type: 'workday', name: '元旦调休', badge: '班' },
    '2026-02-14': { type: 'workday', name: '春节调休', badge: '班' },
    '2026-02-16': { type: 'holiday', name: '春节', badge: '休' },
    '2026-02-17': { type: 'holiday', name: '春节', badge: '休' },
    '2026-02-18': { type: 'holiday', name: '春节', badge: '休' },
    '2026-02-19': { type: 'holiday', name: '春节', badge: '休' },
    '2026-02-20': { type: 'holiday', name: '春节', badge: '休' },
    '2026-02-21': { type: 'holiday', name: '春节', badge: '休' },
    '2026-02-22': { type: 'holiday', name: '春节', badge: '休' },
    '2026-02-23': { type: 'holiday', name: '春节', badge: '休' },
    '2026-02-28': { type: 'workday', name: '春节调休', badge: '班' },
    '2026-04-04': { type: 'holiday', name: '清明节', badge: '休' },
    '2026-04-05': { type: 'holiday', name: '清明节', badge: '休' },
    '2026-04-06': { type: 'holiday', name: '清明节', badge: '休' },
    '2026-04-26': { type: 'workday', name: '劳动节调休', badge: '班' },
    '2026-05-01': { type: 'holiday', name: '劳动节', badge: '休' },
    '2026-05-02': { type: 'holiday', name: '劳动节', badge: '休' },
    '2026-05-03': { type: 'holiday', name: '劳动节', badge: '休' },
    '2026-05-04': { type: 'holiday', name: '劳动节', badge: '休' },
    '2026-05-05': { type: 'holiday', name: '劳动节', badge: '休' },
    '2026-05-09': { type: 'workday', name: '劳动节调休', badge: '班' },
    '2026-06-19': { type: 'holiday', name: '端午节', badge: '休' },
    '2026-06-20': { type: 'holiday', name: '端午节', badge: '休' },
    '2026-06-21': { type: 'holiday', name: '端午节', badge: '休' },
    '2026-09-25': { type: 'holiday', name: '中秋节', badge: '休' },
    '2026-09-26': { type: 'holiday', name: '中秋节', badge: '休' },
    '2026-09-27': { type: 'holiday', name: '中秋节', badge: '休' },
    '2026-09-28': { type: 'workday', name: '国庆节调休', badge: '班' },
    '2026-10-01': { type: 'holiday', name: '国庆节', badge: '休' },
    '2026-10-02': { type: 'holiday', name: '国庆节', badge: '休' },
    '2026-10-03': { type: 'holiday', name: '国庆节', badge: '休' },
    '2026-10-04': { type: 'holiday', name: '国庆节', badge: '休' },
    '2026-10-05': { type: 'holiday', name: '国庆节', badge: '休' },
    '2026-10-06': { type: 'holiday', name: '国庆节', badge: '休' },
    '2026-10-07': { type: 'holiday', name: '国庆节', badge: '休' },
    '2026-10-10': { type: 'workday', name: '国庆节调休', badge: '班' },

    // ===== 2027 年 =====
    '2027-01-01': { type: 'holiday', name: '元旦', badge: '休' },
    '2027-01-02': { type: 'holiday', name: '元旦', badge: '休' },
    '2027-01-03': { type: 'holiday', name: '元旦', badge: '休' },
    '2027-02-05': { type: 'holiday', name: '春节', badge: '休' },
    '2027-02-06': { type: 'holiday', name: '春节', badge: '休' },
    '2027-02-07': { type: 'holiday', name: '春节', badge: '休' },
    '2027-02-08': { type: 'holiday', name: '春节', badge: '休' },
    '2027-02-09': { type: 'holiday', name: '春节', badge: '休' },
    '2027-02-10': { type: 'holiday', name: '春节', badge: '休' },
    '2027-02-11': { type: 'holiday', name: '春节', badge: '休' },
    '2027-02-12': { type: 'holiday', name: '春节', badge: '休' },
    '2027-04-05': { type: 'holiday', name: '清明节', badge: '休' },
    '2027-05-01': { type: 'holiday', name: '劳动节', badge: '休' },
    '2027-05-02': { type: 'holiday', name: '劳动节', badge: '休' },
    '2027-05-03': { type: 'holiday', name: '劳动节', badge: '休' },
    '2027-06-09': { type: 'holiday', name: '端午节', badge: '休' },
    '2027-09-15': { type: 'holiday', name: '中秋节', badge: '休' },
    '2027-10-01': { type: 'holiday', name: '国庆节', badge: '休' },
    '2027-10-02': { type: 'holiday', name: '国庆节', badge: '休' },
    '2027-10-03': { type: 'holiday', name: '国庆节', badge: '休' },
    '2027-10-04': { type: 'holiday', name: '国庆节', badge: '休' },
    '2027-10-05': { type: 'holiday', name: '国庆节', badge: '休' },
    '2027-10-06': { type: 'holiday', name: '国庆节', badge: '休' },
    '2027-10-07': { type: 'holiday', name: '国庆节', badge: '休' }
  };

  /** 将时间戳格式化为 YYYY-MM-DD 字符串 */
  static formatDateKey(dateMs: number): string {
    const d = new Date(dateMs);
    const y = d.getFullYear();
    const m = d.getMonth() + 1;
    const day = d.getDate();
    return `${y}-${m < 10 ? '0' + m : m}-${day < 10 ? '0' + day : day}`;
  }

  /** 查询某一天是否为法定节假日或调休补班日 */
  static getHoliday(dateMs: number): HolidayInfo | null {
    const key = HolidayUtil.formatDateKey(dateMs);
    const info = HolidayUtil.DATA[key];
    return info !== undefined ? info : null;
  }

  /** 获取角标文字（'休' | '班' | ''） */
  static getBadge(dateMs: number): string {
    const h = HolidayUtil.getHoliday(dateMs);
    return h !== null ? h.badge : '';
  }

  /** 节日名称（如"元旦"、"国庆节"等，无节日返回空字符串） */
  static getName(dateMs: number): string {
    const h = HolidayUtil.getHoliday(dateMs);
    return h !== null ? h.name : '';
  }
}
