// entry/src/main/ets/common/SmartDateParser.ets
// 中文自然语言日程解析器（AI 闪念日历：从一句话或剪贴板文本中智能提取时间、地点与标题）

export interface ParsedEventInfo {
  title: string;
  location: string;
  startTime: number;
  endTime: number;
  isAllDay: boolean;
  confidence: boolean; // 是否成功解析出了时间
}

export class SmartDateParser {
  /**
   * 解析自然语言文本，自动提取时间、地点和日程标题
   * 示例：
   *  "明天下午3点在万达星巴克喝咖啡" -> 标题: "喝咖啡", 地点: "万达星巴克", 时间: 明天 15:00-16:00
   *  "下周五晚上8点项目聚餐" -> 标题: "项目聚餐", 时间: 下周五 20:00-21:00
   *  "11月15日全天团建" -> 标题: "团建", 全天: true, 时间: 11-15 00:00-23:59
   */
  static parse(input: string): ParsedEventInfo {
    const raw = input.trim();
    if (raw === '') {
      const now = Date.now();
      return {
        title: '',
        location: '',
        startTime: now,
        endTime: now + 3600000,
        isAllDay: false,
        confidence: false
      };
    }

    let workStr: string = raw;
    const now: Date = new Date();
    const targetDate: Date = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    let hasDate: boolean = false;
    let hasTime: boolean = false;
    let isAllDay: boolean = false;

    // 1. 相对日期（今天、明天、后天、大后天、昨天）
    if (/今天/.test(workStr)) {
      hasDate = true;
      workStr = workStr.replace(/今天/, ' ');
    } else if (/大后天/.test(workStr)) {
      targetDate.setDate(targetDate.getDate() + 3);
      hasDate = true;
      workStr = workStr.replace(/大后天/, ' ');
    } else if (/后天/.test(workStr)) {
      targetDate.setDate(targetDate.getDate() + 2);
      hasDate = true;
      workStr = workStr.replace(/后天/, ' ');
    } else if (/明天/.test(workStr)) {
      targetDate.setDate(targetDate.getDate() + 1);
      hasDate = true;
      workStr = workStr.replace(/明天/, ' ');
    }

    // 2. 星期解析（周一~周日 / 下周一~下周日 / 礼拜一~礼拜日）
    const weekReg = /(?:(本周|这周|下周|下下周|周|星期|礼拜))([一二三四五六日天1-7])/;
    const weekMatch = weekReg.exec(workStr);
    if (weekMatch !== null) {
      hasDate = true;
      const prefix = weekMatch[1];
      const weekChar = weekMatch[2];
      const weekMap: Record<string, number> = {
        '一': 1, '二': 2, '三': 3, '四': 4, '五': 5, '六': 6, '日': 7, '天': 7,
        '1': 1, '2': 2, '3': 3, '4': 4, '5': 5, '6': 6, '7': 7
      };
      const targetDayOfWeek = weekMap[weekChar] !== undefined ? weekMap[weekChar] : 1;
      const curDayOfWeek = now.getDay() === 0 ? 7 : now.getDay();
      let diff = targetDayOfWeek - curDayOfWeek;
      if (prefix === '下周') {
        diff += 7;
      } else if (prefix === '下下周') {
        diff += 14;
      } else if (diff <= 0) {
        diff += 7; // 如果本周已过，默认顺延至下一个对应星期
      }
      targetDate.setDate(now.getDate() + diff);
      workStr = workStr.replace(weekMatch[0], ' ');
    }

    // 3. 具体月日（例如：11月15日、11-15、11.15、2026年11月15日）
    const fullDateReg = /(?:(\d{4})[年\.\-])?(\d{1,2})[月\.\-](\d{1,2})(?:日|号)?/;
    const dateMatch = fullDateReg.exec(workStr);
    if (dateMatch !== null) {
      hasDate = true;
      const y = dateMatch[1] !== undefined ? parseInt(dateMatch[1]) : now.getFullYear();
      const m = parseInt(dateMatch[2]) - 1;
      const d = parseInt(dateMatch[3]);
      targetDate.setFullYear(y, m, d);
      workStr = workStr.replace(dateMatch[0], ' ');
    }

    // 4. 全天标记
    if (/全天|整天/.test(workStr)) {
      isAllDay = true;
      workStr = workStr.replace(/全天|整天/, ' ');
    }

    // 5. 时间解析（上下午/晚上 + 时:分 或 点:分）
    let isPm: boolean = false;
    let isAm: boolean = false;
    if (/(下午|晚上|傍晚|今晚|明晚|晚)/.test(workStr)) {
      isPm = true;
      workStr = workStr.replace(/(下午|晚上|傍晚|今晚|明晚|晚)/, ' ');
    } else if (/(上午|早上|早晨|早|清晨)/.test(workStr)) {
      isAm = true;
      workStr = workStr.replace(/(上午|早上|早晨|早|清晨)/, ' ');
    } else if (/中午/.test(workStr)) {
      workStr = workStr.replace(/中午/, ' ');
    }

    let startHour: number = 9;
    let startMin: number = 0;

    // 匹配如 15:30, 3点半, 8点, 8点45分, 8:00
    const timeReg = /(\d{1,2})(?:[:：点点hH](\d{1,2})?分?)?/;
    const timeMatch = timeReg.exec(workStr);
    if (timeMatch !== null) {
      const hStr = timeMatch[1];
      const mStr = timeMatch[2];
      let h = parseInt(hStr);
      let m = 0;
      if (mStr !== undefined && mStr !== '') {
        m = parseInt(mStr);
      } else if (workStr.includes(`${hStr}点半`)) {
        m = 30;
      }
      if (h <= 12 && isPm && h !== 12) {
        h += 12;
      }
      if (h === 12 && isAm) {
        h = 0;
      }
      if (h >= 0 && h < 24 && m >= 0 && m < 60) {
        startHour = h;
        startMin = m;
        hasTime = true;
        workStr = workStr.replace(timeMatch[0], ' ');
        workStr = workStr.replace('点半', ' ');
      }
    }

    // 6. 地点提取（匹配 "在 / 于 / 到 / 位于" 后面的地点名称）
    let location: string = '';
    const locReg = /(?:在|于|位于|到)([\u4e00-\u9fa5a-zA-Z0-9_\-\s]{2,20}?)(?:(?:去|开会|喝咖啡|聚餐|碰面|面试|吃饭|看电影|分享|交流|汇报|打球|见|讨论|商议|聊天)|$)/;
    const locMatch = locReg.exec(workStr);
    if (locMatch !== null && locMatch[1].trim() !== '') {
      location = locMatch[1].trim();
      workStr = workStr.replace(locMatch[0], ' ' + (locMatch[0].replace(locMatch[1], '').replace(/在|于|位于|到/, '')));
    }

    // 7. 清理多余介词和标点，提取核心标题
    let cleanTitle = workStr
      .replace(/[\s\t,，。！!、~～:：\-—]+/g, ' ')
      .replace(/^(去|在|于|跟|和|与|进行|参加)/, '')
      .trim();

    if (cleanTitle === '' && raw !== '') {
      cleanTitle = raw;
    }

    // 8. 组装起止时间戳
    let startTs: number = 0;
    let endTs: number = 0;
    if (isAllDay) {
      targetDate.setHours(0, 0, 0, 0);
      startTs = targetDate.getTime();
      endTs = startTs + 86400000;
    } else {
      targetDate.setHours(startHour, startMin, 0, 0);
      startTs = targetDate.getTime();
      endTs = startTs + 3600000; // 默认时长 1 小时
    }

    return {
      title: cleanTitle,
      location: location,
      startTime: startTs,
      endTime: endTs,
      isAllDay: isAllDay,
      confidence: hasDate || hasTime
    };
  }
}

