// entry/src/main/ets/common/CalendarDataService.ets
// 合并数据源：本地库（DAV 同步 + 本机事件） + 系统日历（只读展示）
import { common, abilityAccessCtrl, bundleManager, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { calendarManager } from '@kit.CalendarKit';
import { AccountStore, CalSource, BookPalette, LOCAL_CAL_KEY, DavAccount } from './AccountStore';
import { EventDb, LocalEvent } from './EventDb';
import { LogUtil } from './LogUtil';
import { AppSettings } from './AppSettings';
import { RruleUtil } from './RruleUtil';
import { IcsUtil } from './IcsUtil';

/** 界面展示用事件 */
export class DisplayEvent {
  id: number = 0;          // 本地库 id 或系统日历事件 id
  isSystem: boolean = false;
  title: string = '';
  description: string = '';
  location: string = '';
  startTime: number = 0;
  endTime: number = 0;
  isAllDay: boolean = false;
  calKey: string = '';
  calName: string = '';
  color: string = '#007DFF';
  completed: boolean = false; // 仅待办使用
  recurring: boolean = false; // 是否为重复日程展开出的发生
  writable: boolean = true;   // 所属日历本是否可写（只读时点击显示详情而非编辑）
}

export class CalendarDataService {
  /** 本功能依赖的日历权限：读取本应用日历 + 读取全部日历（即"读取全部日程"） */
  private static readonly CALENDAR_PERMISSIONS: Permissions[] = [
    'ohos.permission.READ_CALENDAR',
    'ohos.permission.READ_WHOLE_CALENDAR'
  ];

  /**
   * 是否已获得"读取全部日程"权限。
   * **只检查、绝不弹窗** —— 供界面判断状态、决定是否需要引导用户主动授权。
   * 注意：checkAccessToken 只反映本应用授权状态，不会触发任何系统弹窗。
   */
  static async hasSystemCalendarPermission(): Promise<boolean> {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const info = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      const tokenId: number = info.appInfo.accessTokenId;
      for (const p of CalendarDataService.CALENDAR_PERMISSIONS) {
        const status = await atManager.checkAccessToken(tokenId, p);
        if (status !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
          return false;
        }
      }
      return true;
    } catch (err) {
      return false;
    }
  }

  /**
   * 申请"读取全部日程"权限（READ_CALENDAR + READ_WHOLE_CALENDAR）。
   *
   * ⚠️ 合规约束（《审核指南》7.17）：**只能在用户主动点击使用对应功能时调用**，
   * 例如在设置页打开"混合显示系统日历"开关、把系统日历模式切到"备份到 CalDAV 日历本"。
   * 严禁在 App 启动 / 首次打开 / 未同意隐私政策等用户未主动操作的时机调用。
   *
   * 已授权时直接返回 true，不会再弹窗（先 checkAccessToken，避免多余弹窗）。
   */
  static async requestSystemCalendarPermission(context: common.UIAbilityContext): Promise<boolean> {
    if (await CalendarDataService.hasSystemCalendarPermission()) {
      return true;
    }
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const result = await atManager.requestPermissionsFromUser(
        context, CalendarDataService.CALENDAR_PERMISSIONS);
      for (const r of result.authResults) {
        if (r !== 0) {
          return false;
        }
      }
      return true;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`日历权限申请失败: ${e.code} - ${e.message}`);
      return false;
    }
  }

  /** 收集全部日历来源：DAV 日历本 + 本机 + 系统日历账户 */
  static async loadSources(context: common.Context): Promise<CalSource[]> {
    const sources: CalSource[] = [];
    const manualKeys: string[] = await AppSettings.getManualReadonlyKeys(context);
    try {
      const accounts: DavAccount[] = await AccountStore.loadAll(context);
      for (const acc of accounts) {
        for (let i = 0; i < acc.calendarHrefs.length; i++) {
          const s = new CalSource();
          s.calKey = `${acc.id}_${i}`;
          let name: string = i < acc.calendarNames.length ? acc.calendarNames[i] : '';
          if (name === '') {
            name = acc.calendarHrefs.length === 1 ? acc.name : `日历本 ${i + 1}`;
          }
          s.name = `${acc.name}:${name}`;
          // 优先使用服务器端定义的颜色；未定义时按**集合 href** 派生（不随顺序变化，见 colorForHref 说明）
          let color: string = i < acc.calendarColors.length ? AccountStore.normalizeColor(acc.calendarColors[i]) : '';
          s.color = color !== '' ? color : BookPalette.colorForHref(acc.calendarHrefs[i]);
          s.source = 'dav';
          s.visible = true;
          // 写权限：服务器探测结果 + 手动标记（部分服务器不在 CalDAV 层拒绝写入）
          const detected: boolean = acc.calendarWritable.length > i
            ? acc.calendarWritable[i] !== '0' : true;
          s.writable = detected && !manualKeys.includes(s.calKey);
          sources.push(s);
        }
      }
      // 本机事件虚拟日历
      const local = new CalSource();
      local.calKey = LOCAL_CAL_KEY;
      local.name = '本机';
      local.color = '#5A6068';
      local.source = 'local';
      local.visible = true;
      sources.push(local);
    } catch (err) {
      const e = err as BusinessError;
      console.error(`加载 DAV 来源失败: ${e.message}`);
    }
    // 系统日历账户（受"混合显示系统日历"开关控制；按账户名去重）
    const showSys: boolean = await AppSettings.getShowSystemCalendar(context);
    if (!showSys) {
      LogUtil.write('来源加载：系统日历混合显示已关闭，跳过全部系统日历');
    } else {
      try {
        const uiContext = context as common.UIAbilityContext;
        const mgr: calendarManager.CalendarManager = calendarManager.getCalendarManager(uiContext);
        const calendars: calendarManager.Calendar[] = await mgr.getAllCalendars();
        let sysRaw: number = 0;
        for (const cal of calendars) {
          try {
            const account: calendarManager.CalendarAccount = cal.getAccount();
            sysRaw++;
            const sysKey: string = `sys_${account.name}`;
            if (sources.some((x: CalSource): boolean => x.calKey === sysKey)) {
              continue; // 同名账户只保留一个来源
            }
            const s = new CalSource();
            s.calKey = sysKey;
            s.name = '系统';
            let color = '#9AA0A6';
            const config: calendarManager.CalendarConfig = cal.getConfig();
            if (typeof config.color === 'string') {
              color = config.color;
            }
            s.color = color;
            s.source = 'system';
            s.visible = true;
            sources.push(s);
          } catch (err) {
            // 单个日历账户读取失败不影响整体
          }
        }
        LogUtil.write(`来源加载：系统日历 ${sysRaw} 个（按账户去重后保留，共 ${sources.length} 个来源）`);
      } catch (err) {
        const e = err as BusinessError;
        console.info(`系统日历不可用(可能未授权): ${e.code}`);
      }
    }
    return sources;
  }

  /** 加载时间区间内的合并事件（按来源显隐过滤） */
  static async loadEvents(context: common.Context, start: number, end: number,
    sources: CalSource[]): Promise<DisplayEvent[]> {
    LogUtil.init(context);
    const result: DisplayEvent[] = [];
    const visibleKeys: string[] = sources.filter((s: CalSource): boolean => s.visible)
      .map((s: CalSource): string => s.calKey);
    const colorOf = (key: string): string => {
      const found = sources.find((s: CalSource): boolean => s.calKey === key);
      return found !== undefined ? found.color : '#9AA0A6';
    };
    const nameOf = (key: string): string => {
      const found = sources.find((s: CalSource): boolean => s.calKey === key);
      return found !== undefined ? found.name : '';
    };
    const writableOf = (key: string): boolean => {
      const found = sources.find((s: CalSource): boolean => s.calKey === key);
      return found !== undefined ? found.writable : true;
    };

    // 1) 本地库（DAV + 本机）；重复日程(RRULE)按规则展开为窗口内的多次发生
    try {
      const rows: LocalEvent[] = await EventDb.queryRange(context, start, end);
      // 重复主事件的首次发生可能在窗口外，也纳入（仅用于展开）
      const masters: LocalEvent[] = await EventDb.queryRecurringMasters(context, end);
      for (const m of masters) {
        if (!rows.some((r: LocalEvent): boolean => r.id === m.id)) {
          rows.push(m);
        }
      }
      // 单次覆盖实例（RECURRENCE-ID 独立行）：展开时跳过对应发生，避免重复。
      // 注意：①排除键必须带 calKey（同一系列可能出现在多个日历本）；
      // ②只有"可见日历本"的覆盖行才参与排除——历史孤儿行（旧账号迁移残留）
      //    自己不显示，却会把主事件的对应发生排除掉，导致"第一次不显示"
      const overrideKeys: string[] = [];
      for (const e of rows) {
        if (e.rrule === '' && e.recurring && visibleKeys.includes(e.calKey)) {
          overrideKeys.push(`${e.calKey}_${e.uid}_${e.startTime}`);
        }
      }
      let occTotal: number = 0;
      for (const e of rows) {
        if (!visibleKeys.includes(e.calKey)) {
          continue;
        }
        const baseColor: string = colorOf(e.calKey);
        const baseName: string = nameOf(e.calKey);
        const dur: number = Math.max(0, e.endTime - e.startTime);
        let times: number[] = [e.startTime];
        if (e.rrule !== '') {
          const exNums: number[] = [];
          if (e.exdate !== '') {
            for (const raw of e.exdate.split(';')) {
              const t = IcsUtil.parseTime(raw, !raw.includes('T'));
              if (t !== null) {
                exNums.push(t.time);
              }
            }
          }
          const occs: number[] = RruleUtil.expand(e.rrule, e.startTime, start, end, exNums, 1500);
          if (occs.length > 0) {
            times = occs.filter((occ: number): boolean =>
              !overrideKeys.includes(`${e.calKey}_${e.uid}_${occ}`));
          }
        }
        for (const occ of times) {
          const d = new DisplayEvent();
          d.id = e.id;
          d.isSystem = false;
          d.title = e.title;
          d.description = e.description;
          d.location = e.location;
          d.startTime = occ;
          d.endTime = occ + dur;
          d.isAllDay = e.isAllDay;
          d.calKey = e.calKey;
          d.calName = baseName;
          d.color = baseColor;
          d.recurring = e.rrule !== '';
          d.writable = writableOf(e.calKey);
          result.push(d);
          occTotal++;
        }
      }
      LogUtil.write(`显示加载：本地库 ${rows.length} 行，展开后 ${occTotal} 条（区间 ${new Date(start).toLocaleString()} ~ ${new Date(end).toLocaleString()}）`);
    } catch (err) {
      const e = err as BusinessError;
      console.error(`读取本地事件失败: ${e.message}`);
    }

    // 2) 系统日历（只读混合展示）——单日历失败只跳过该日历，不影响其余
    if (visibleKeys.some((k: string): boolean => k.startsWith('sys_'))) {
      try {
        const uiContext = context as common.UIAbilityContext;
        const mgr: calendarManager.CalendarManager = calendarManager.getCalendarManager(uiContext);
        const calendars: calendarManager.Calendar[] = await mgr.getAllCalendars();
        for (const cal of calendars) {
          let accountName: string = '';
          let color = '#9AA0A6';
          try {
            const account: calendarManager.CalendarAccount = cal.getAccount();
            accountName = account.name;
            const config: calendarManager.CalendarConfig = cal.getConfig();
            if (typeof config.color === 'string') {
              color = config.color;
            }
          } catch (err) {
            // 忽略单个日历
          }
          const sysKey: string = `sys_${accountName}`;
          if (!visibleKeys.includes(sysKey)) {
            continue;
          }
          try {
            const events: calendarManager.Event[] = await cal.queryEventInstances(start, end);
            let skipped: number = 0;
            for (const ev of events) {
              const d = new DisplayEvent();
              d.id = ev.id !== undefined ? ev.id : 0;
              d.isSystem = true;
              d.title = ev.title !== undefined ? ev.title : '(无标题)';
              d.description = ev.description !== undefined ? ev.description : '';
              d.location = ev.location !== undefined && ev.location.location !== undefined ? ev.location.location : '';
              d.startTime = ev.startTime;
              d.endTime = ev.endTime;
              d.isAllDay = ev.isAllDay === true;
              d.calKey = sysKey;
              d.calName = nameOf(sysKey);
              d.color = color;
              // 去重：与本地(DAV/本机)同标题+同时间的视为同一条，避免两个来源重复展示
              const dup: boolean = result.some((x: DisplayEvent): boolean => !x.isSystem &&
                x.title === d.title && x.startTime === d.startTime &&
                x.endTime === d.endTime && x.isAllDay === d.isAllDay);
              if (!dup) {
                result.push(d);
              } else {
                skipped++;
              }
            }
            LogUtil.write(`系统日历 ${sysKey}：查询到 ${events.length} 条，与本地重复跳过 ${skipped} 条`);
          } catch (err) {
            const e = err as BusinessError;
            console.info(`查询系统日历 ${sysKey} 失败(跳过): ${e.code}`);
          }
        }
      } catch (err) {
        const e = err as BusinessError;
        console.info(`读取系统日历失败(可能未授权): ${e.code}`);
      }
    }
    // 排序：全天日程最前，然后按开始时间
    result.sort((a: DisplayEvent, b: DisplayEvent): number => {
      if (a.isAllDay !== b.isAllDay) {
        return a.isAllDay ? -1 : 1;
      }
      return a.startTime - b.startTime;
    });
    return result;
  }

  /** 加载全部待办（VTODO，来自 DAV 同步，只读展示） */
  static async loadTodos(context: common.Context, sources: CalSource[]): Promise<DisplayEvent[]> {
    const result: DisplayEvent[] = [];
    const visibleKeys: string[] = sources.filter((s: CalSource): boolean => s.visible)
      .map((s: CalSource): string => s.calKey);
    const colorOf = (key: string): string => {
      const found = sources.find((s: CalSource): boolean => s.calKey === key);
      return found !== undefined ? found.color : '#9AA0A6';
    };
    try {
      const rows: LocalEvent[] = await EventDb.queryTodos(context);
      for (const e of rows) {
        if (!visibleKeys.includes(e.calKey)) {
          continue;
        }
        const d = new DisplayEvent();
        d.id = e.id;
        d.isSystem = false;
        d.title = e.title;
        d.description = e.description;
        d.location = e.location;
        d.startTime = e.startTime;
        d.endTime = e.endTime;
        d.isAllDay = e.isAllDay;
        d.calKey = e.calKey;
        d.color = colorOf(e.calKey);
        d.completed = e.completed;
        result.push(d);
      }
    } catch (err) {
      const e = err as BusinessError;
      console.error(`读取待办失败: ${e.message}`);
    }
    return result;
  }
}