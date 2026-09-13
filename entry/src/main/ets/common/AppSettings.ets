// entry/src/main/ets/common/AppSettings.ets
// 应用级设置（preferences 持久化）
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

export class AppSettings {
  private static readonly STORE: string = 'sync_settings';
  private static readonly KEY_SHOW_SYSTEM: string = 'show_system_calendar';
  private static readonly KEY_SYNC_INTERVAL: string = 'sync_interval_minutes';
  private static readonly KEY_BACKGROUND_SYNC: string = 'background_sync';
  private static readonly KEY_SYS_MODE: string = 'sys_cal_mode';       // 'display' | 'backup'
  private static readonly KEY_BACKUP_KEY: string = 'sys_backup_cal_key'; // 备份目标 DAV 日历本
  private static readonly KEY_MANUAL_READONLY: string = 'manual_readonly_keys'; // 手动标记只读的 calKey

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
