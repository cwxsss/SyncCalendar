// entry/src/main/ets/common/ScreenKeeper.ets
// 同步期间保持屏幕常亮：鸿蒙熄屏后应用进程会被挂起，网络请求停摆导致同步超时。
// 引用计数支持多处同步（首页/账号页/后台入口）叠加，最后一个释放时才恢复熄屏。
import { window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';

export class ScreenKeeper {
  private static count: number = 0;

  /** 同步开始时调用：保持屏幕常亮（失败静默，不影响同步） */
  static async acquire(context: common.UIAbilityContext): Promise<void> {
    ScreenKeeper.count++;
    try {
      const win = await window.getLastWindow(context);
      await win.setWindowKeepScreenOn(true);
    } catch (err) {
      // 获取窗口失败（如页面已销毁）不影响同步
    }
  }

  /** 同步结束时调用：恢复系统默认熄屏策略 */
  static async release(context: common.UIAbilityContext): Promise<void> {
    ScreenKeeper.count = Math.max(0, ScreenKeeper.count - 1);
    if (ScreenKeeper.count > 0) {
      return; // 还有其他同步在进行，保持常亮
    }
    try {
      const win = await window.getLastWindow(context);
      await win.setWindowKeepScreenOn(false);
    } catch (err) {
      // 忽略
    }
  }
}
