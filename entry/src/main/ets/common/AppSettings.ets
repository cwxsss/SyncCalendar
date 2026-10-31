// entry/src/main/ets/common/AppSettings.ets
// 应用级设置（preferences 持久化）
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { LogUtil } from './LogUtil';

export class AppSettings {
  private static readonly STORE: string = 'sync_settings';
  private static readonly KEY_SHOW_SYSTEM: string = 'show_system_calendar';
  private static readonly KEY_SYNC_INTERVAL: string = 'sync_interval_minutes';
  private static readonly KEY_BACKGROUND_SYNC: string = 'background_sync';
  private static readonly KEY_SYS_MODE: string = 'sys_cal_mode';       // 'display' | 'backup'
  // ⚠️ 备份目标**必须**用稳定标识 bookId 存（由服务器 href 派生，见 SystemCalendarMirror.listBooks）。
  //    老键存的是 calKey（`accId_序号`），序号会随"取消勾选某个日历本/服务器新增日历本"整体漂移
  //    → 目标本会**悄悄变成另一个本**，把系统日历导进用户没选过的本（用户实测发现）。
  //    KEY_BACKUP_KEY 仅保留用于老值一次性迁移，读到后立即换存 KEY_BACKUP_BOOK_ID 并清空。
  private static readonly KEY_BACKUP_KEY: string = 'sys_backup_cal_key';   // 【已废弃】备份目标 calKey（仅迁移用）
  private static readonly KEY_BACKUP_BOOK_ID: string = 'sys_backup_book_id'; // ⭐ 备份目标稳定标识 bookId
  private static readonly KEY_MANUAL_READONLY: string = 'manual_readonly_keys'; // 手动标记只读的 calKey
  private static readonly KEY_MUTED_REMINDER: string = 'muted_reminder_keys';  // 提醒静音的 calKey
  private static readonly KEY_REMINDER_TICK: string = 'reminder_tick';         // 应用内提醒上次检查时间戳
  // ⭐ 卡片刷新驱动的后台同步：上次执行时间戳（用于节流）。
  //   服务卡片每 30 分钟被系统刷新一次（form_config 的 updateDuration=1），
  //   借这个时机顺带跑一次后台同步 —— 得到"约 30 分钟一次"的定期同步。
  private static readonly KEY_CARD_SYNC_AT: string = 'card_sync_at';
  /** ⭐ 诊断开关：卡片驱动同步的时间预算（毫秒）。0/未设置 = 用内置默认（见 BackgroundSyncRunner）。
   *  留给真机排查用 —— 不用重编译就能做"9 秒 vs 长窗口"对照实验。 */
  private static readonly KEY_CARD_BUDGET_MS: string = 'card_budget_ms';
  private static readonly KEY_FULL_REFETCH: string = 'full_refetch_done'; // 一次性全量重拉已完成
  private static readonly KEY_DEFAULT_VIEW: string = 'default_view';      // 打开 App 默认视图
  private static readonly KEY_DISPLAY_STYLE: string = 'display_style';    // 日程显示方式：'timeline' | 'list'
  private static readonly KEY_CARD_DAYS_RANGE: string = 'card_days_range'; // 桌面卡片日程显示天数跨度：1 | 3 | 7
  private static readonly KEY_MIRROR_ENABLED: string = 'mirror_enabled';   // 是否把选中 CalDAV 日历本镜像到系统日历（默认关）
  private static readonly KEY_MIRROR_KEYS: string = 'mirror_cal_keys';     // 要镜像的 DAV 日历本 calKey 列表
  private static readonly KEY_MIRROR_BOOK_IDS: string = 'mirror_book_ids'; // ⭐ 要镜像的日历本**稳定标识** bookId（由服务器 href 派生，不随序号变）
  private static readonly KEY_MIRROR_INBOUND: string = 'mirror_inbound';   // 是否把系统日历的改动回写 CalDAV（默认关）
  // ⭐ 系统日历账户的**显示名格式**（1/2/3，默认 3=`<账号>·<本名>`）。
  //    因平台无"改账户名"API，切换格式需删账户重建（用户显式点「应用」才执行）。
  private static readonly KEY_MIRROR_DISPLAY_FORMAT: string = 'mirror_display_format';
  private static readonly KEY_POLICY_AGREED: string = 'policy_agreed';    // 是否已同意隐私政策与用户协议
  // 首启功能引导"用户已看过并关闭"的标记。键名带版本号：改动引导内容后把 vN 加 1，用户即可再看一次。
  // 注意：只在用户主动关闭（"开始使用" / ✕ / 点遮罩）时才置 true，**不再"显示前就置 true"**——
  // 否则一旦某次因故没显示出来，旧标记会把功能永久锁死（v2 正是这样被锁住 → 本次升到 v3）。
  private static readonly KEY_TIPS_SHOWN: string = 'tips_shown_v3';

  // 在线文档网址（自托管，AGC 上架的"隐私政策网址"填 PRIVACY_URL）。
  // ⚠️ 隐私政策与用户协议必须与安装包实际申请的 user_grant 权限保持一致：
  //    应用仅申请 READ_CALENDAR / READ_WHOLE_CALENDAR / WRITE_CALENDAR（均前台）。
  //    文档中不得出现"在后台获取位置"（LOCATION_IN_BACKGROUND）。
  // ⚠️ 0.1.0 起已**移除 LOCATION / APPROXIMATELY_LOCATION**：实测本 SDK（API 26）的
  //     `geoLocationManager.getAddressesFromLocationName`（地址→坐标）无 @permission 标注，
  //     地理编码不需要定位权限；且应用从不调用 getCurrentLocation，本就不读实时位置。
  //     ⇒ 隐私政策/隐私标签里都**不得**再声称"读取设备精确位置或大致位置"。
  //     ⇒ 若将来真要用实时定位，必须同时改 module.json5、本注释、upa.html 与 AGC 隐私标签。
  // 四份文档均在设置页通过内置浏览器（DocViewer）打开，内容在线更新、无需重新发版。
  /** 隐私政策网址 */
  static readonly PRIVACY_URL: string = 'https://synccalendar.yangyq.net/upa.html';
  /** 用户服务协议网址 */
  static readonly AGREEMENT_URL: string = 'https://synccalendar.yangyq.net/usa.html';
  /** 软件特性网址 */
  static readonly FEATURES_URL: string = 'https://synccalendar.yangyq.net/sf.html';
  /** 使用帮助网址 */
  static readonly HELP_URL: string = 'https://synccalendar.yangyq.net/uh.html';
  /** 文档标题（内置浏览器标题栏用） */
  static readonly PRIVACY_TITLE: string = '隐私政策';
  static readonly AGREEMENT_TITLE: string = '用户服务协议';
  static readonly FEATURES_TITLE: string = '软件特性';
  static readonly HELP_TITLE: string = '使用帮助';

  /**
   * 是否已同意《隐私政策》与《用户协议》（首启同意弹窗）。
   * 默认 false —— 未同意前不得申请任何系统权限、不得加载/同步数据。
   */
  static async getPolicyAgreed(context: common.Context): Promise<boolean> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      return await store.get(AppSettings.KEY_POLICY_AGREED, false) as boolean;
    } catch (err) {
      return false;
    }
  }

  static async setPolicyAgreed(context: common.Context, value: boolean): Promise<void> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      await store.put(AppSettings.KEY_POLICY_AGREED, value);
      await store.flush();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`保存隐私政策同意状态失败: ${e.message}`);
    }
  }

  /**
   * 首启功能引导卡片是否已展示过（避免每次启动都弹）。
   * 默认 false —— 启动（首次同意后 / 已同意用户再次启动）时若为 false 会自动弹出一次并置为 true。
   */
  static async getTipsShown(context: common.Context): Promise<boolean> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      return await store.get(AppSettings.KEY_TIPS_SHOWN, false) as boolean;
    } catch (err) {
      return false;
    }
  }

  static async setTipsShown(context: common.Context, value: boolean): Promise<void> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      await store.put(AppSettings.KEY_TIPS_SHOWN, value);
      await store.flush();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`保存功能引导展示状态失败: ${e.message}`);
    }
  }

  /** 打开 App 后默认展示的视图：'month' | 'month_expanded' | 'week' | 'agenda'（默认 month） */
  static async getDefaultView(context: common.Context): Promise<string> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      const v: string = await store.get(AppSettings.KEY_DEFAULT_VIEW, 'month') as string;
      return (v === 'week' || v === 'agenda' || v === 'month_expanded') ? v : 'month';
    } catch (err) {
      return 'month';
    }
  }

  static async setDefaultView(context: common.Context, view: string): Promise<void> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      await store.put(AppSettings.KEY_DEFAULT_VIEW, view);
      await store.flush();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`保存默认视图失败: ${e.message}`);
    }
  }

  /**
   * 日程显示方式：'timeline'（竖向时间轴，默认） | 'list'（列表）。
   *
   * 两种风格各有偏好：时间轴强于"看一天的时间占用与冲突"，列表强于"快速扫读与长标题"。
   * 该设置同时作用于主界面（月/周视图下方、列表视图）与桌面服务卡片（4×4 / 6×4）。
   * 列表模式下不绘制"当前时间红线"（列表没有时间刻度，红线没有落点）。
   */
  static async getDisplayStyle(context: common.Context): Promise<string> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      const v: string = await store.get(AppSettings.KEY_DISPLAY_STYLE, 'timeline') as string;
      return v === 'list' ? 'list' : 'timeline';
    } catch (err) {
      return 'timeline';
    }
  }

  static async setDisplayStyle(context: common.Context, style: string): Promise<void> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      await store.put(AppSettings.KEY_DISPLAY_STYLE, style === 'list' ? 'list' : 'timeline');
      await store.flush();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`保存日程显示方式失败: ${e.message}`);
    }
  }

  /**
   * 桌面卡片日程显示天数跨度：1（当天） | 3（未来3天） | 7（未来7天）。默认 1。
   */
  static async getCardDaysRange(context: common.Context): Promise<number> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      const v: number = await store.get(AppSettings.KEY_CARD_DAYS_RANGE, 1) as number;
      return (v === 3 || v === 7) ? v : 1;
    } catch (err) {
      return 1;
    }
  }

  static async setCardDaysRange(context: common.Context, days: number): Promise<void> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      const val: number = (days === 3 || days === 7) ? days : 1;
      await store.put(AppSettings.KEY_CARD_DAYS_RANGE, val);
      await store.flush();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`保存卡片显示天数跨度失败: ${e.message}`);
    }
  }

  /**
   * 是否把选中的 CalDAV 日历本镜像到系统日历（默认关）。
   * ⚠️ 该开关必须与 WRITE_CALENDAR 授权状态一致：未授权即为关（权限按需申请约束）。
   */
  static async getMirrorEnabled(context: common.Context): Promise<boolean> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      return await store.get(AppSettings.KEY_MIRROR_ENABLED, false) as boolean;
    } catch (err) {
      return false;
    }
  }

  static async setMirrorEnabled(context: common.Context, value: boolean): Promise<void> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      await store.put(AppSettings.KEY_MIRROR_ENABLED, value);
      await store.flush();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`保存镜像开关失败: ${e.message}`);
    }
  }

  /**
   * ⚠️ **已废弃**：早期用 calKey 存"要镜像哪些本"，但 calKey 是 `<账号ID>_<序号>`，
   *     日历本重排后序号会变 → 选中的本串成另一个本、镜像账户名也变 → 系统日历出现重复账户与串本。
   *     新代码一律用 `getMirrorBookIds()`。这里只为读取历史值做迁移。
   */
  static async getMirrorKeys(context: common.Context): Promise<string[]> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      const raw: string = await store.get(AppSettings.KEY_MIRROR_KEYS, '') as string;
      if (raw === '') {
        return [];
      }
      const arr: string[] = JSON.parse(raw) as string[];
      if (!Array.isArray(arr)) {
        return [];
      }
      const out: string[] = [];
      for (let i: number = 0; i < arr.length; i++) {
        const v: string = arr[i];
        if (typeof v === 'string' && v !== '') {
          out.push(v);
        }
      }
      return out;
    } catch (err) {
      return [];
    }
  }

  static async setMirrorKeys(context: common.Context, keys: string[]): Promise<void> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      await store.put(AppSettings.KEY_MIRROR_KEYS, JSON.stringify(keys));
      await store.flush();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`保存镜像日历本失败: ${e.message}`);
    }
  }

  /**
   * ⭐ 要镜像到系统日历的日历本**稳定标识** bookId 列表，空 = 未选择。
   * bookId = `<账号ID>-<href哈希>`，由服务器分配的 href 派生 —— 日历本增删改序都不会变。
   */
  static async getMirrorBookIds(context: common.Context): Promise<string[]> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      const raw: string = await store.get(AppSettings.KEY_MIRROR_BOOK_IDS, '') as string;
      if (raw === '') {
        return [];
      }
      const arr: string[] = JSON.parse(raw) as string[];
      if (!Array.isArray(arr)) {
        return [];
      }
      const out: string[] = [];
      for (let i: number = 0; i < arr.length; i++) {
        const v: string = arr[i];
        if (typeof v === 'string' && v !== '') {
          out.push(v);
        }
      }
      return out;
    } catch (err) {
      return [];
    }
  }

  static async setMirrorBookIds(context: common.Context, ids: string[]): Promise<void> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      await store.put(AppSettings.KEY_MIRROR_BOOK_IDS, JSON.stringify(ids));
      await store.flush();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`保存镜像日历本(bookId)失败: ${e.message}`);
    }
  }

  /**
   * 是否把"用户在系统日历里的改动"回写到 CalDAV（**默认关**）。
   * ⚠️ 默认关是有意的：这个功能会写用户的服务器数据，首次上线必须先单向观察一轮再开。
   */
  static async getMirrorInbound(context: common.Context): Promise<boolean> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      return await store.get(AppSettings.KEY_MIRROR_INBOUND, false) as boolean;
    } catch (err) {
      return false;
    }
  }

  static async setMirrorInbound(context: common.Context, value: boolean): Promise<void> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      await store.put(AppSettings.KEY_MIRROR_INBOUND, value);
      await store.flush();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`保存回写开关失败: ${e.message}`);
    }
  }

  /**
   * ⭐ 系统日历账户显示名格式：1=`同步日历·本名`，2=`同步日历·账号·本名`，3=`账号·本名`（默认）。
   * 只接受 1/2/3，其它值一律回落到默认 3（防止脏数据导致拼出意外名字）。
   */
  static async getMirrorDisplayFormat(context: common.Context): Promise<number> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      const v = await store.get(AppSettings.KEY_MIRROR_DISPLAY_FORMAT, 3) as number;
      return (v === 1 || v === 2 || v === 3) ? v : 3;
    } catch (err) {
      return 3;
    }
  }

  static async setMirrorDisplayFormat(context: common.Context, value: number): Promise<void> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      await store.put(AppSettings.KEY_MIRROR_DISPLAY_FORMAT, value);
      await store.flush();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`保存显示名格式失败: ${e.message}`);
    }
  }

  /** ⭐ 卡片刷新驱动的后台同步：上次执行时间戳（0 = 从未执行） */
  static async getCardSyncAt(context: common.Context): Promise<number> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      return await store.get(AppSettings.KEY_CARD_SYNC_AT, 0) as number;
    } catch (err) {
      return 0;
    }
  }

  static async setCardSyncAt(context: common.Context, ts: number): Promise<void> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      await store.put(AppSettings.KEY_CARD_SYNC_AT, ts);
      await store.flush();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`保存卡片同步时间失败: ${e.message}`);
    }
  }

  /** ⭐ 诊断用：卡片驱动同步的时间预算（毫秒）。0 = 未设置（用内置默认值）。 */
  static async getCardBudgetMs(context: common.Context): Promise<number> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      return await store.get(AppSettings.KEY_CARD_BUDGET_MS, 0) as number;
    } catch (err) {
      return 0;
    }
  }

  /**
   * 是否还需要一次性全量重拉：修复历史同步（REPORT 剥离 VALARM 时期）落库的残缺数据。
   * 全量重拉期间忽略 etag 复用，所有资源 GET 完整 ICS；成功完成后标记，恢复增量模式。
   */
  static async isFullRefetchPending(context: common.Context): Promise<boolean> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      return !(await store.get(AppSettings.KEY_FULL_REFETCH, false) as boolean);
    } catch (err) {
      return true;
    }
  }

  static async markFullRefetchDone(context: common.Context): Promise<void> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      await store.put(AppSettings.KEY_FULL_REFETCH, true);
      await store.flush();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`标记全量重拉完成失败: ${e.message}`);
    }
  }

  /**
   * 手动重置全量重拉标记：下次同步忽略 etag 复用，所有资源 GET 完整 ICS 重建本地数据。
   * 用于修复历史落库的残缺字段（如 reminder=0 但 etag 从未变化，增量同步永远无法纠正）。
   */
  static async resetFullRefetch(context: common.Context): Promise<void> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      await store.put(AppSettings.KEY_FULL_REFETCH, false);
      await store.flush();
      LogUtil.write('已重置全量重拉标记：下次同步将 GET 全部资源重建本地数据');
    } catch (err) {
      const e = err as BusinessError;
      console.error(`重置全量重拉标记失败: ${e.message}`);
    }
  }

  /**
   * 手动标记为只读的日历本 calKey 列表。
   * 部分服务器（如群晖某些共享方式）不在 CalDAV 层拒绝写入，自动探测无法区分，
   * 由用户手动标记，标记后其中日程只显示详情、不出现在新建日程选择中。
   */
  static async getManualReadonlyKeys(context: common.Context): Promise<string[]> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      const raw: string = await store.get(AppSettings.KEY_MANUAL_READONLY, '') as string;
      return raw === '' ? [] : raw.split(';');
    } catch (err) {
      return [];
    }
  }

  static async setManualReadonlyKeys(context: common.Context, keys: string[]): Promise<void> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      await store.put(AppSettings.KEY_MANUAL_READONLY, keys.join(';'));
      await store.flush();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`保存手动只读标记失败: ${e.message}`);
    }
  }

  /**
   * 提醒静音的日历本 calKey 列表。
   * 适用于别人分享的日历本：静音后其中所有日程都不再发布系统提醒（日程本身仍正常显示）。
   */
  static async getMutedReminderKeys(context: common.Context): Promise<string[]> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      const raw: string = await store.get(AppSettings.KEY_MUTED_REMINDER, '') as string;
      return raw === '' ? [] : raw.split(';');
    } catch (err) {
      return [];
    }
  }

  static async setMutedReminderKeys(context: common.Context, keys: string[]): Promise<void> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      await store.put(AppSettings.KEY_MUTED_REMINDER, keys.join(';'));
      await store.flush();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`保存提醒静音标记失败: ${e.message}`);
    }
  }

  /** 应用内提醒模式的上次检查时间戳（毫秒，0 = 未初始化） */
  static async getReminderTick(context: common.Context): Promise<number> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      return await store.get(AppSettings.KEY_REMINDER_TICK, 0) as number;
    } catch (err) {
      return 0;
    }
  }

  static async setReminderTick(context: common.Context, tick: number): Promise<void> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      await store.put(AppSettings.KEY_REMINDER_TICK, tick);
      await store.flush();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`保存提醒检查时间戳失败: ${e.message}`);
    }
  }

  /**
   * 删除账号后的设置清理：移除该账号名下所有日历本的
   * 手动只读标记、提醒静音标记，并清空指向它的备份目标。
   */
  static async cleanupAccountSettings(context: common.Context, accId: string): Promise<void> {
    try {
      const manual: string[] = await AppSettings.getManualReadonlyKeys(context);
      const manual2: string[] = manual.filter((k: string): boolean => !k.startsWith(`${accId}_`));
      if (manual2.length !== manual.length) {
        await AppSettings.setManualReadonlyKeys(context, manual2);
      }
      const muted: string[] = await AppSettings.getMutedReminderKeys(context);
      const muted2: string[] = muted.filter((k: string): boolean => !k.startsWith(`${accId}_`));
      if (muted2.length !== muted.length) {
        await AppSettings.setMutedReminderKeys(context, muted2);
      }
      // 备份目标指向该账号名下某个本 → 目标必失效：清空目标**并关闭备份功能**
      // （只清空目标会让"备份到 CalDAV"开关停在开着却什么都不做的状态，状态与实际不符）
      const bookId: string = await AppSettings.getBackupBookId(context);
      const legacyKey: string = await AppSettings.getBackupCalKey(context);
      if (bookId.startsWith(`${accId}-`) || legacyKey.startsWith(`${accId}_`)) {
        await AppSettings.clearBackupTarget(context);
        await AppSettings.setSysCalMode(context, 'display');
        console.log(`删除账号 ${accId}：其名下的系统日历备份目标已失效，备份功能自动关闭`);
      }
    } catch (err) {
      const e = err as BusinessError;
      console.error(`清理账号设置失败: ${e.message}`);
    }
  }

  /** 系统日历模式：display = 仅混合显示；backup = 本地系统日程备份到选定 CalDAV 日历本 */
  static async getSysCalMode(context: common.Context): Promise<string> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      return await store.get(AppSettings.KEY_SYS_MODE, 'display') as string;
    } catch (err) {
      return 'display';
    }
  }

  static async setSysCalMode(context: common.Context, mode: string): Promise<void> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      await store.put(AppSettings.KEY_SYS_MODE, mode);
      await store.flush();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`保存系统日历模式失败: ${e.message}`);
    }
  }

  /**
   * 【已废弃，仅供老值迁移】备份目标 calKey（`accId_序号`）。
   * ⚠️ 不要再用它做判断！序号会漂移（见 KEY_BACKUP_KEY 处注释）。
   *    新代码一律用 `SystemCalendarMirror.backupTargetRef()` / `checkBackupTarget()`，
   *    它内部会把这个老值翻译成 bookId 并清空本键。
   */
  static async getBackupCalKey(context: common.Context): Promise<string> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      return await store.get(AppSettings.KEY_BACKUP_KEY, '') as string;
    } catch (err) {
      return '';
    }
  }

  /** 【已废弃】写老键。新代码请用 setBackupBookId()。 */
  static async setBackupCalKey(context: common.Context, calKey: string): Promise<void> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      await store.put(AppSettings.KEY_BACKUP_KEY, calKey);
      await store.flush();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`保存备份目标(老键)失败: ${e.message}`);
    }
  }

  /** ⭐ 备份目标日历本的稳定标识 bookId（`<accId>-<href哈希>`），空 = 未选择 */
  static async getBackupBookId(context: common.Context): Promise<string> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      return await store.get(AppSettings.KEY_BACKUP_BOOK_ID, '') as string;
    } catch (err) {
      return '';
    }
  }

  /** ⭐ 保存备份目标（bookId）。传空字符串 = 取消选择。 */
  static async setBackupBookId(context: common.Context, bookId: string): Promise<void> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      await store.put(AppSettings.KEY_BACKUP_BOOK_ID, bookId);
      await store.flush();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`保存备份目标失败: ${e.message}`);
    }
  }

  /** 一次清空备份目标（新键 + 老键一起清，避免迁移残留又复活） */
  static async clearBackupTarget(context: common.Context): Promise<void> {
    await AppSettings.setBackupBookId(context, '');
    await AppSettings.setBackupCalKey(context, '');
  }

  /** 是否开启后台持续同步（长时任务，默认关） */
  static async getBackgroundSync(context: common.Context): Promise<boolean> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      return await store.get(AppSettings.KEY_BACKGROUND_SYNC, false) as boolean;
    } catch (err) {
      return false;
    }
  }

  static async setBackgroundSync(context: common.Context, value: boolean): Promise<void> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      await store.put(AppSettings.KEY_BACKGROUND_SYNC, value);
      await store.flush();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`保存后台同步设置失败: ${e.message}`);
    }
  }

  /**
   * 是否混合显示系统日历日程。
   * ⚠️ 默认**关闭**：读取系统日历需要"读取全部日程"敏感权限，按《审核指南》7.17
   * 只能在用户主动打开该开关时才申请，因此默认值必须与实际授权状态一致（无授权 = 关）。
   */
  static async getShowSystemCalendar(context: common.Context): Promise<boolean> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      return await store.get(AppSettings.KEY_SHOW_SYSTEM, false) as boolean;
    } catch (err) {
      return false;
    }
  }

  static async setShowSystemCalendar(context: common.Context, value: boolean): Promise<void> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      await store.put(AppSettings.KEY_SHOW_SYSTEM, value);
      await store.flush();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`保存设置失败: ${e.message}`);
    }
  }

  /**
   * 自动同步间隔（分钟），默认 15 分钟。
   *
   * ⭐ 0.0.8：默认值由 1 分钟改为 15 分钟。原因（真机日志 2026-10-16 17:16–17:20 实测）：
   * 1 分钟间隔会让「App 打开期间」几乎不间断地跑"12 个日历本全量比对 + 出站镜像 + 提醒刷新"，
   * 5 分钟内连跑 5 轮后触发系统提示「短时任务超时（配额用尽），后台同步将被挂起」——
   * 反而把真正的后台同步通道一起拖垮。改为 15 分钟后，前台同步仍足够及时，且不再烧配额。
   * 用户仍可在设置页自行改成 1 / 5 / 15 / 30 分钟 或 1 小时。
   */
  static async getSyncIntervalMinutes(context: common.Context): Promise<number> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      const v: number = await store.get(AppSettings.KEY_SYNC_INTERVAL, 15) as number;
      return v > 0 ? v : 15;
    } catch (err) {
      return 15;
    }
  }

  static async setSyncIntervalMinutes(context: common.Context, minutes: number): Promise<void> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      await store.put(AppSettings.KEY_SYNC_INTERVAL, minutes);
      await store.flush();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`保存同步间隔失败: ${e.message}`);
    }
  }
}
