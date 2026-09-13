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
