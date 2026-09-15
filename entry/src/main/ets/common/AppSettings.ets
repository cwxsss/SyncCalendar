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
  private static readonly KEY_BACKUP_KEY: string = 'sys_backup_cal_key'; // 备份目标 DAV 日历本
  private static readonly KEY_MANUAL_READONLY: string = 'manual_readonly_keys'; // 手动标记只读的 calKey
  private static readonly KEY_MUTED_REMINDER: string = 'muted_reminder_keys';  // 提醒静音的 calKey
  private static readonly KEY_REMINDER_TICK: string = 'reminder_tick';         // 应用内提醒上次检查时间戳
  private static readonly KEY_FULL_REFETCH: string = 'full_refetch_done'; // 一次性全量重拉已完成
  private static readonly KEY_DEFAULT_VIEW: string = 'default_view';      // 打开 App 默认视图
  private static readonly KEY_POLICY_AGREED: string = 'policy_agreed';    // 是否已同意隐私政策与用户协议
  // 首启功能引导"用户已看过并关闭"的标记。键名带版本号：改动引导内容后把 vN 加 1，用户即可再看一次。
  // 注意：只在用户主动关闭（"开始使用" / ✕ / 点遮罩）时才置 true，**不再"显示前就置 true"**——
  // 否则一旦某次因故没显示出来，旧标记会把功能永久锁死（v2 正是这样被锁住 → 本次升到 v3）。
  private static readonly KEY_TIPS_SHOWN: string = 'tips_shown_v3';

  // 隐私政策 / 用户服务协议网址（自托管，AGC 上架的"隐私政策网址"填 PRIVACY_URL）。
  // ⚠️ 两份文件必须与安装包实际申请的 user_grant 权限保持一致：
  //    应用仅申请 READ_CALENDAR / READ_WHOLE_CALENDAR / LOCATION / APPROXIMATELY_LOCATION（均前台），
  //    文档中不得出现"在后台获取位置"（LOCATION_IN_BACKGROUND）与"添加/修改/删除日历活动"（WRITE_CALENDAR）。
  /** 隐私政策网址 */
  static readonly PRIVACY_URL: string = 'https://synccalendar.yangyq.net/upa.html';
  /** 用户服务协议网址 */
  static readonly AGREEMENT_URL: string = 'https://synccalendar.yangyq.net/usa.html';
  /** 文档标题（内置浏览器标题栏用） */
  static readonly PRIVACY_TITLE: string = '隐私政策';
  static readonly AGREEMENT_TITLE: string = '用户服务协议';

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

  /** 打开 App 后默认展示的视图：'month' | 'week' | 'agenda'（默认 month） */
  static async getDefaultView(context: common.Context): Promise<string> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      const v: string = await store.get(AppSettings.KEY_DEFAULT_VIEW, 'month') as string;
      return (v === 'week' || v === 'agenda') ? v : 'month';
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
      const backupKey: string = await AppSettings.getBackupCalKey(context);
      if (backupKey.startsWith(`${accId}_`)) {
        await AppSettings.setBackupCalKey(context, '');
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

  /** 备份目标日历本 calKey（accId_序号），空 = 未选择 */
  static async getBackupCalKey(context: common.Context): Promise<string> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      return await store.get(AppSettings.KEY_BACKUP_KEY, '') as string;
    } catch (err) {
      return '';
    }
  }

  static async setBackupCalKey(context: common.Context, calKey: string): Promise<void> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      await store.put(AppSettings.KEY_BACKUP_KEY, calKey);
      await store.flush();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`保存备份目标失败: ${e.message}`);
    }
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

  /** 是否混合显示系统日历日程（默认开） */
  static async getShowSystemCalendar(context: common.Context): Promise<boolean> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      return await store.get(AppSettings.KEY_SHOW_SYSTEM, true) as boolean;
    } catch (err) {
      return true;
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

  /** 自动同步间隔（分钟），默认 1 分钟 */
  static async getSyncIntervalMinutes(context: common.Context): Promise<number> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AppSettings.STORE);
      const v: number = await store.get(AppSettings.KEY_SYNC_INTERVAL, 1) as number;
      return v > 0 ? v : 1;
    } catch (err) {
      return 1;
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
